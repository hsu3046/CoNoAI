// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import Foundation

struct LyricsTimingSnapshot: Equatable, Sendable {
    let trackID: String
    let position: Double
    let captureTime: Double
    let isPlaying: Bool
    let discontinuities: Int
}

enum LyricsTapSyncError: LocalizedError {
    case invalidText, playbackUnavailable, wrongTrack, seekDetected, notArmed, nonIncreasingTime, finished, incomplete

    var errorDescription: String? {
        switch self {
        case .invalidText: "시간 태그 없는 일반 가사를 입력해 주세요. 최대 1 MB, 4,000줄, 한 줄 500글자입니다."
        case .playbackUnavailable: "소리가 재생될 때 기록을 켜 주세요. 일시정지·버퍼링·이동 중에는 기록하지 않습니다."
        case .wrongTrack: "편집 중인 곡과 다른 곡이 재생되고 있어요. 원래 곡으로 돌아오면 이어서 기록할 수 있습니다."
        case .seekDetected: "재생 위치가 바뀌어 기록을 멈췄어요. 다음 줄을 확인한 뒤 기록을 다시 켜 주세요."
        case .notArmed: "‘기록 켜기’를 누른 뒤 줄이 시작될 때 Space를 눌러 주세요."
        case .nonIncreasingTime: "이전 줄보다 뒤의 시각이어야 해요. 잘못 찍은 줄은 되돌리기로 지울 수 있습니다."
        case .finished: "모든 줄의 시각을 기록했어요. 미리보기에서 확인한 뒤 저장해 주세요."
        case .incomplete: "모든 줄의 시각을 기록한 뒤 저장하거나 내보내 주세요."
        }
    }
}

/// 입력 초안은 저장 전까지 현재 가사와 분리된다. UI와 무관하게 재생·곡·탐색 안전성을 검사한다.
struct LyricsTapSync: Sendable {
    private static let timingTag = try! NSRegularExpression(pattern: #"<([^<>]*)>|\[([^\[\]]*)\]"#)
    let trackID: String
    let lines: [String]
    private(set) var timestamps: [Double] = []
    private(set) var isArmed = false
    private(set) var interruption: String?
    private var observed: LyricsTimingSnapshot?

    init(trackID: String, plainLyrics: String) throws {
        guard plainLyrics.utf8.count <= 1_048_576 else { throw LyricsTapSyncError.invalidText }
        let lines = plainLyrics.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty, lines.count <= 4_000,
              lines.allSatisfy({ $0.count <= 500 && !Self.containsTimingTag($0) }) else {
            throw LyricsTapSyncError.invalidText
        }
        self.trackID = trackID
        self.lines = lines
    }

    private static func containsTimingTag(_ line: String) -> Bool {
        let source = line as NSString
        return timingTag.matches(in: line, range: NSRange(location: 0, length: source.length)).contains { match in
            for group in 1...2 where match.range(at: group).location != NSNotFound {
                if LRCParser.parseTime(source.substring(with: match.range(at: group))) != nil { return true }
            }
            return false
        }
    }

    var isComplete: Bool { timestamps.count == lines.count }
    var plainLyrics: String { lines.joined(separator: "\n") }
    var preview: TimedLyrics { TimedLyrics(lines: zip(timestamps, lines).map { LyricLine(start: $0.0, text: $0.1) }) }

    /// 100ms 미리보기 틱마다 전체 가사를 만들거나 파싱하지 않는다.
    func previewText(at seconds: Double) -> String? {
        guard seconds.isFinite, !timestamps.isEmpty else { return nil }
        var low = 0
        var high = timestamps.count
        while low < high {
            let middle = (low + high) / 2
            if timestamps[middle] <= seconds { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return nil }
        let index = low - 1
        let next = index + 1 < timestamps.count ? timestamps[index + 1] : .infinity
        guard seconds < min(next, timestamps[index] + TimedLyrics.maxLineDuration) else { return nil }
        return lines[index]
    }

    mutating func arm(at snapshot: LyricsTimingSnapshot?) throws {
        guard !isComplete else { throw LyricsTapSyncError.finished }
        let snapshot = try valid(snapshot)
        observed = snapshot
        isArmed = true
        interruption = nil
    }

    mutating func disarm() { isArmed = false; observed = nil }

    mutating func observe(_ snapshot: LyricsTimingSnapshot?) {
        guard isArmed else { return }
        do {
            let next = try valid(snapshot)
            if let previous = observed {
                let positionDelta = next.position - previous.position
                let captureDelta = next.captureTime - previous.captureTime
                guard next.discontinuities == previous.discontinuities, captureDelta >= 0,
                      abs(positionDelta - captureDelta) <= 0.5 else { throw LyricsTapSyncError.seekDetected }
            }
            observed = next
        } catch {
            disarm()
            interruption = error.localizedDescription
        }
    }

    mutating func record(at snapshot: LyricsTimingSnapshot?) throws {
        observe(snapshot)
        guard isArmed else { throw LyricsTapSyncError.notArmed }
        let snapshot = try valid(snapshot)
        guard !isComplete else { throw LyricsTapSyncError.finished }
        let time = (snapshot.position * 1_000).rounded() / 1_000
        guard time < 86_400, timestamps.last.map({ time > $0 }) ?? true else { throw LyricsTapSyncError.nonIncreasingTime }
        timestamps.append(time)
        if isComplete { disarm() }
    }

    mutating func undo() { disarm(); if !timestamps.isEmpty { timestamps.removeLast() }; interruption = nil }
    mutating func reset() { disarm(); timestamps.removeAll(); interruption = nil }

    func lrc() throws -> String {
        guard isComplete else { throw LyricsTapSyncError.incomplete }
        // 태그 뒤 공백은 [후렴] 같은 본문을 LRC 메타데이터로 오인하지 않게 한다.
        let lrc = zip(timestamps, lines).map { "[\(Self.timestamp($0.0))] \($0.1)" }.joined(separator: "\n") + "\n"
        guard LRCParser.parse(lrc) == preview else { throw LyricsTapSyncError.invalidText }
        return lrc
    }

    static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds <= 86_400 else { return "--:--.---" }
        let milliseconds = Int((seconds * 1_000).rounded())
        return String(format: "%02d:%02d.%03d", milliseconds / 60_000, milliseconds / 1_000 % 60, milliseconds % 1_000)
    }

    private func valid(_ snapshot: LyricsTimingSnapshot?) throws -> LyricsTimingSnapshot {
        guard let snapshot, snapshot.isPlaying, snapshot.position.isFinite, snapshot.captureTime.isFinite,
              snapshot.position >= 0, snapshot.position < 86_400 else { throw LyricsTapSyncError.playbackUnavailable }
        guard snapshot.trackID == trackID else { throw LyricsTapSyncError.wrongTrack }
        return snapshot
    }
}

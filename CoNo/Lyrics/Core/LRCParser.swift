// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// LRC 싱크 가사 파서.
//   [mm:ss.xx]가사   [mm:ss.xxx]   [mm:ss]   한 줄에 여러 시각 태그 [00:12.00][00:45.00]후렴
//   [offset:+250] (ms, 양수 = 가사를 앞당김 — LRC 관례)   [ar:] [ti:] 등 메타 태그는 무시
//   <mm:ss.xx> 단어 태그(enhanced LRC)는 지금은 제거만 한다.

import Foundation

struct LyricLine: Equatable, Sendable {
    /// 곡 안 시작 시각 (초)
    let start: Double
    let text: String

    /// 빈 줄 = 간주(연주 구간) 표시
    var isInterlude: Bool { text.isEmpty }
}

struct TimedLyrics: Equatable, Sendable {
    /// 시작 시각 오름차순
    let lines: [LyricLine]

    /// 한 줄이 이어진다고 볼 최대 길이 (다음 줄이 한참 뒤면 여기서 끊는다)
    static let maxLineDuration: Double = 10

    /// 곡 위치 t 에서 부르고 있는 줄 (없으면 nil — 첫 줄 전이거나 간주)
    func lineIndex(at t: Double) -> Int? {
        var low = 0
        var high = lines.count - 1
        var found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].start <= t {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard let index = found, t < end(of: index) else { return nil }
        return lines[index].isInterlude ? nil : index
    }

    /// 줄 끝 = 다음 줄 시작 (최대 maxLineDuration)
    func end(of index: Int) -> Double {
        let start = lines[index].start
        let next = index + 1 < lines.count ? lines[index + 1].start : start + Self.maxLineDuration
        return min(next, start + Self.maxLineDuration)
    }

    /// t 이후 처음 시작하는 가사 줄 (간주 제외)
    func nextLineIndex(after t: Double) -> Int? {
        lines.firstIndex { $0.start > t && !$0.isInterlude }
    }
}

enum LRCParser {
    static func parse(_ lrc: String) -> TimedLyrics {
        // 같은 시각의 줄이 여럿이면 첫 줄만 남긴다 (병기 가사의 번역 줄).
        // 그대로 두면 앞 줄은 길이 0 이라 영원히 안 보이고, 어느 줄이 보일지가 정렬 순서에 달린다.
        var lines: [LyricLine] = []
        for line in timedLines(lrc) {
            if let last = lines.last, last.start == line.start {
                if last.isInterlude, !line.isInterlude { lines[lines.count - 1] = line }
                continue
            }
            lines.append(line)
        }
        return TimedLyrics(lines: lines)
    }

    /// 가사 줄 중 다른 가사 줄과 시각이 똑같은 줄의 비율. 원문·번역을 같은 시각에 겹쳐 둔 병기 가사를 알아보는 데 쓴다.
    static func sharedTimestampRatio(_ lrc: String) -> Double {
        let starts = timedLines(lrc).filter { !$0.isInterlude }.map(\.start)
        guard !starts.isEmpty else { return 0 }
        var counts: [Double: Int] = [:]
        for start in starts { counts[start, default: 0] += 1 }
        let shared = starts.filter { (counts[$0] ?? 0) > 1 }.count
        return Double(shared) / Double(starts.count)
    }

    /// 시각순(같은 시각은 원래 순서) 줄 목록. offset 적용.
    private static func timedLines(_ lrc: String) -> [LyricLine] {
        var offsetSeconds = 0.0
        var lines: [LyricLine] = []

        for rawLine in lrc.components(separatedBy: .newlines) {
            var rest = Substring(rawLine.trimmingCharacters(in: .whitespaces))
            var times: [Double] = []

            // 줄 앞의 [..] 태그들을 차례로 벗긴다
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                rest = rest[rest.index(after: close)...]
                if let time = parseTime(tag) {
                    times.append(time)
                } else if tag.lowercased().hasPrefix("offset:"), let ms = Double(tag.dropFirst("offset:".count).trimmingCharacters(in: .whitespaces)) {
                    offsetSeconds = ms / 1000
                }
                // 그 밖의 메타 태그([ar:], [ti:] …)는 무시
            }
            guard !times.isEmpty else { continue }

            let text = stripWordTags(String(rest)).trimmingCharacters(in: .whitespaces)
            for time in times {
                lines.append(LyricLine(start: time, text: text))
            }
        }

        // offset 은 양수면 가사를 앞당긴다 (start − offset). 같은 시각은 원래 순서를 지킨다 (sorted 는 안정 정렬 보장이 없다).
        return lines.enumerated()
            .map { (order: $0.offset, line: LyricLine(start: max(0, $0.element.start - offsetSeconds), text: $0.element.text)) }
            .sorted { ($0.line.start, $0.order) < ($1.line.start, $1.order) }
            .map(\.line)
    }

    /// "mm:ss", "mm:ss.xx", "mm:ss.xxx", "mm:ss:xx"
    static func parseTime<S: StringProtocol>(_ tag: S) -> Double? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              let minutes = Int(parts[0].trimmingCharacters(in: .whitespaces)), minutes >= 0
        else { return nil }
        let secondsText: String
        if parts.count == 3 {
            // mm:ss:xx (드물게 쓰이는 표기)
            secondsText = "\(parts[1]).\(parts[2])"
        } else {
            secondsText = String(parts[1])
        }
        guard let seconds = Double(secondsText.trimmingCharacters(in: .whitespaces)), seconds >= 0, seconds < 60 else { return nil }
        return Double(minutes) * 60 + seconds
    }

    /// enhanced LRC 의 <mm:ss.xx> 단어 태그 제거
    private static func stripWordTags(_ text: String) -> String {
        guard text.contains("<") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "<", let close = text[index...].firstIndex(of: ">"),
               parseTime(text[text.index(after: index)..<close]) != nil {
                index = text.index(after: close)
            } else {
                result.append(text[index])
                index = text.index(after: index)
            }
        }
        return result
    }
}

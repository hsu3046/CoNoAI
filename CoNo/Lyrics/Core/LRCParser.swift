// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// LRC 싱크 가사 파서.
//   [mm:ss.xx]가사   [mm:ss.xxx]   [mm:ss]   한 줄에 여러 시각 태그 [00:12.00][00:45.00]후렴
//   [offset:+250] (ms, 양수 = 가사를 앞당김 — LRC 관례)   [ar:] [ti:] 등 메타 태그는 무시
//   <mm:ss.xx> 단어 태그(enhanced LRC)는 글자 범위와 시작·끝 시각으로 보존한다.

import Foundation

/// 화면의 Character 기준 범위. UTF-16 바이트/코드 유닛으로 세면 한글·이모지 색칠이 어긋난다.
struct LyricSegment: Equatable, Sendable {
    let characterStart: Int
    let characterCount: Int
    let start: Double
    /// 마지막 단어에 종료 태그가 없으면 다음 줄 시작(일반 LRC와 같은 상한)을 쓴다.
    let end: Double?
}

struct LyricLine: Equatable, Sendable {
    /// 곡 안 시작 시각 (초)
    let start: Double
    let text: String
    var segments: [LyricSegment] = []
    var explicitEnd: Double? = nil

    /// 빈 줄 = 간주(연주 구간) 표시
    var isInterlude: Bool { text.isEmpty }

    /// 원본 단어 시각이 있는 줄은 보컬 추정/캐시 없이 곡 시각으로 바로 계산한다.
    /// 단어 사이의 쉼표·숨 구간에서는 앞 단어 끝에 머무르며 seek 후에도 이전 색칠에 묶이지 않는다.
    func highlightedCharacters(at time: Double, lineEnd: Double) -> Double? {
        guard !segments.isEmpty else { return nil }
        var completed = 0.0
        for segment in segments {
            guard time >= segment.start else { return completed }
            let end = min(segment.end ?? lineEnd, lineEnd)
            if time >= end {
                completed = Double(segment.characterStart + segment.characterCount)
            } else {
                let fraction = end > segment.start ? (time - segment.start) / (end - segment.start) : 1
                return Double(segment.characterStart) + min(max(fraction, 0), 1) * Double(segment.characterCount)
            }
        }
        return completed
    }
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

    /// 원본 종료 태그는 긴 멜리스마도 보존한다. 일반 줄은 기존의 10초 상한을 유지한다.
    func end(of index: Int) -> Double {
        let start = lines[index].start
        let naturalEnd = lines[index].explicitEnd ?? start + Self.maxLineDuration
        let next = index + 1 < lines.count ? lines[index + 1].start : naturalEnd
        return min(next, naturalEnd)
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
                } else if tag.lowercased().hasPrefix("offset:"), let ms = Double(tag.dropFirst("offset:".count).trimmingCharacters(in: .whitespaces)),
                          ms.isFinite, abs(ms) <= 86_400_000 {
                    offsetSeconds = ms / 1000
                }
                // 그 밖의 메타 태그([ar:], [ti:] …)는 무시
            }
            guard !times.isEmpty else { continue }

            let parsed = wordSegments(String(rest), lineStart: times[0])
            for time in times {
                // 여러 줄 시작 태그의 반복 후렴: 단어 시각도 첫 줄과의 차이만큼 함께 이동한다.
                lines.append(shifted(parsed, by: time - times[0]))
            }
        }

        // offset 은 양수면 가사를 앞당긴다 (start − offset). 같은 시각은 원래 순서를 지킨다 (sorted 는 안정 정렬 보장이 없다).
        return lines.enumerated()
            .map { (order: $0.offset, line: shifted($0.element, by: -offsetSeconds)) }
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
        guard let seconds = Double(secondsText.trimmingCharacters(in: .whitespaces)), seconds.isFinite, seconds >= 0, seconds < 60 else { return nil }
        let total = Double(minutes) * 60 + seconds
        return total <= 86_400 ? total : nil
    }

    private static func shifted(_ line: LyricLine, by offset: Double) -> LyricLine {
        LyricLine(start: max(0, line.start + offset), text: line.text,
                  segments: line.segments.map {
                      LyricSegment(characterStart: $0.characterStart, characterCount: $0.characterCount,
                                   start: max(0, $0.start + offset), end: $0.end.map { max(0, $0 + offset) })
                  }, explicitEnd: line.explicitEnd.map { max(0, $0 + offset) })
    }

    /// 시작 태그 사이의 글자 범위가 단어. 빈/공백 구간의 태그는 이전 단어의 정확한 종료점이다.
    private static func wordSegments(_ text: String, lineStart: Double) -> LyricLine {
        var result = ""
        var characterCount = 0
        var boundaries: [(character: Int, time: Double)] = [(0, lineStart)]
        var hasTags = false
        var validTimes = true
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "<", let close = text[index...].firstIndex(of: ">"),
               let time = parseTime(text[text.index(after: index)..<close]) {
                hasTags = true
                if time < (boundaries.last?.time ?? lineStart) { validTimes = false }
                boundaries.append((characterCount, time))
                index = text.index(after: close)
            } else {
                result.append(text[index])
                characterCount += 1
                index = text.index(after: index)
            }
        }
        let characters = Array(result)
        let leading = characters.prefix(while: { $0.isWhitespace }).count
        let trailing = characters.reversed().prefix(while: { $0.isWhitespace }).count
        let upper = max(leading, characters.count - trailing)
        let plain = String(characters[leading..<upper])
        guard hasTags, validTimes, !plain.isEmpty else { return LyricLine(start: lineStart, text: plain) }
        let explicitEnd = boundaries.last.flatMap { $0.character >= upper ? $0.time : nil }
        // TTML의 줄 종료만 전달한 경우. 한 줄 전체를 단어로 만들어 보컬 기반 색칠을 막지 않는다.
        guard boundaries.dropFirst().contains(where: { $0.character < upper }) else {
            return LyricLine(start: lineStart, text: plain, explicitEnd: explicitEnd)
        }

        var segments: [LyricSegment] = []
        for i in boundaries.indices {
            let from = max(boundaries[i].character, leading)
            let to = min(i + 1 < boundaries.count ? boundaries[i + 1].character : characters.count, upper)
            guard from < to else { continue }
            let fragment = characters[from..<to]
            let a = from + fragment.prefix(while: { $0.isWhitespace }).count
            let b = to - fragment.reversed().prefix(while: { $0.isWhitespace }).count
            guard a < b else { continue }
            let end = i + 1 < boundaries.count ? boundaries[i + 1].time : nil
            segments.append(LyricSegment(characterStart: a - leading, characterCount: b - a,
                                         start: boundaries[i].time, end: end))
        }
        return LyricLine(start: lineStart, text: plain, segments: segments, explicitEnd: explicitEnd)
    }
}

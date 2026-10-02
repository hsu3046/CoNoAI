// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import Foundation

enum SRTError: LocalizedError {
    case invalidCue(Int), overlappingCues

    var errorDescription: String? {
        switch self {
        case let .invalidCue(number): "SRT의 \(number)번째 자막 시간을 읽지 못했어요. 시각은 시:분:초,밀리초 형식이어야 합니다."
        case .overlappingCues: "동시에 겹치는 SRT 자막은 한 줄로 합친 뒤 가져와 주세요."
        }
    }
}

/// SRT의 종료 시각을 보존한다. 자막 사이 공백을 10초짜리 가사로 늘리지 않는다.
enum SRTParser {
    static func parse(_ source: String) throws -> TimedLyrics {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var blocks: [[String]] = []
        var block: [String] = []
        for line in normalized.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !block.isEmpty { blocks.append(block); block = [] }
            } else { block.append(line) }
        }
        if !block.isEmpty { blocks.append(block) }
        var lyrics: [LyricLine] = []
        for (index, lines) in blocks.enumerated() {
            let first = lines[0].trimmingCharacters(in: .whitespaces)
            let timeIndex = !first.isEmpty && first.allSatisfy(\.isNumber) ? 1 : 0
            guard lines.count > timeIndex + 1 else { throw SRTError.invalidCue(index + 1) }
            let pair = lines[timeIndex].components(separatedBy: "-->")
            guard pair.count == 2, let start = seconds(pair[0]), let end = seconds(pair[1]), end > start else {
                throw SRTError.invalidCue(index + 1)
            }
            let text = lines.dropFirst(timeIndex + 1).map { line in
                line.replacingOccurrences(of: "</?(?:b|i|u|font)(?:\\s+[^>]*)?>", with: "", options: [.regularExpression, .caseInsensitive])
                    .trimmingCharacters(in: .whitespaces)
            }.joined(separator: " ")
            guard !text.isEmpty else { throw SRTError.invalidCue(index + 1) }
            lyrics.append(LyricLine(start: start, text: text, explicitEnd: end))
        }
        lyrics.sort { $0.start < $1.start }
        for index in lyrics.indices.dropFirst() {
            guard lyrics[index - 1].explicitEnd! <= lyrics[index].start else { throw SRTError.overlappingCues }
        }
        return TimedLyrics(lines: lyrics)
    }

    private static func seconds(_ input: String) -> Double? {
        let value = input.trimmingCharacters(in: .whitespaces)
        guard value.range(of: "^[0-9]{2,3}:[0-5][0-9]:[0-5][0-9][,.][0-9]{3}$", options: .regularExpression) != nil else { return nil }
        let parts = value.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2]) else { return nil }
        let result = hours * 3_600 + minutes * 60 + seconds
        return result <= 86_400 ? result : nil
    }
}

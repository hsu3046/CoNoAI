// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// 가사 한 줄 → 노래 단위(음절) 목록.
//   한글 음절·가나·한자: 한 글자 = 한 단위 (대개 한 음표에 한 글자)
//   작은 가나(ゃゅょっ…)·장음(ー): 앞 단위에 붙인다 (같은 음표 안에서 발음)
//   라틴 문자·숫자: 단어 = 한 단위, 무게 = 모음 묶음 수 (대략의 음절 수)
//   공백·문장부호: 무게 0, 앞 단위에 붙인다 (맨 앞이면 다음 단위에)

import Foundation

struct LyricUnit: Equatable, Sendable {
    /// 줄 텍스트의 Character 배열 기준 [start, end)
    let charStart: Int
    let charEnd: Int
    /// 예상 발성 시간 비중 (음절 수)
    let weight: Double

    var charCount: Int { charEnd - charStart }
}

enum LyricTokenizer {
    static func units(_ text: String) -> [LyricUnit] {
        let characters = Array(text)
        var units: [(start: Int, end: Int, weight: Double)] = []
        var pendingLeading = 0 // 첫 단위 앞의 공백·문장부호 개수
        var index = 0

        while index < characters.count {
            let character = characters[index]
            switch kind(of: character) {
            case .syllable:
                units.append((index - (units.isEmpty ? pendingLeading : 0), index + 1, 1))
                pendingLeading = 0
                index += 1
            case .attachesToPrevious, .separator:
                if units.isEmpty {
                    pendingLeading += 1
                } else {
                    units[units.count - 1].end = index + 1
                }
                index += 1
            case .latin:
                var end = index
                while end < characters.count, kind(of: characters[end]) == .latin { end += 1 }
                let word = String(characters[index..<end])
                units.append((index - (units.isEmpty ? pendingLeading : 0), end, Double(max(1, vowelGroups(in: word)))))
                pendingLeading = 0
                index = end
            }
        }
        return units.map { LyricUnit(charStart: $0.start, charEnd: $0.end, weight: $0.weight) }
    }

    private enum Kind {
        case syllable, attachesToPrevious, separator, latin
    }

    private static func kind(of character: Character) -> Kind {
        guard let scalar = character.unicodeScalars.first else { return .separator }
        switch scalar.value {
        // 작은 가나·장음·촉음: 앞 글자와 같은 음표
        case 0x3041, 0x3043, 0x3045, 0x3047, 0x3049, 0x3063, 0x3083, 0x3085, 0x3087, 0x308E,
             0x30A1, 0x30A3, 0x30A5, 0x30A7, 0x30A9, 0x30C3, 0x30E3, 0x30E5, 0x30E7, 0x30EE,
             0x30FC:
            return .attachesToPrevious
        case 0xAC00...0xD7A3, // 한글 음절
             0x3040...0x309F, 0x30A0...0x30FF, // 히라가나·가타카나
             0x4E00...0x9FFF, 0x3400...0x4DBF: // 한자
            return .syllable
        default:
            break
        }
        if character.isLetter || character.isNumber { return .latin }
        return .separator
    }

    /// 영단어의 모음 묶음 수 (대략의 음절 수)
    private static func vowelGroups(in word: String) -> Int {
        var groups = 0
        var inVowel = false
        for character in word.lowercased() {
            let isVowel = "aeiouyàáâäèéêëìíîïòóôöùúûü".contains(character)
            if isVowel, !inVowel { groups += 1 }
            inVowel = isVowel
        }
        return groups
    }
}

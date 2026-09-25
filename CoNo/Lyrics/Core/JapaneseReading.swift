// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// 일본어 가사의 한자 읽기 → 글자별 모라(박자) 수.
// 한자는 한 글자가 여러 박자다 (誰=だれ 2, 想=おも 2). 이를 모르면 음절 정렬이 중간에서 밀린다.
// macOS 내장 형태소 분석(CFStringTokenizer, 로케일 ja)의 로마자 표기로 토큰 모라 수를 세고,
// 토큰 안 가나 몫을 뺀 나머지를 한자에 고르게 나눈다.
//   예) 誰[dare] 想っ[omo~tsu] 香り[kaori] 今頃[imagoro] 東京[toukyou]

import CoreFoundation
import Foundation

enum JapaneseReading {
    /// 한자 글자(Character 인덱스) → 모라 수. 읽기를 못 구하면 그 글자는 빠진다 (호출자가 1 로 본다).
    static func kanjiMorae(in text: String) -> [Int: Double] {
        let characters = Array(text)
        guard characters.contains(where: isKanji) else { return [:] }

        let cfText = text as CFString
        let tokenizer = CFStringTokenizerCreate(
            nil, cfText, CFRange(location: 0, length: CFStringGetLength(cfText)),
            kCFStringTokenizerUnitWord, Locale(identifier: "ja") as CFLocale
        )
        var result: [Int: Double] = [:]
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            guard let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String,
                  let swiftRange = Range(NSRange(location: range.location, length: range.length), in: text)
            else { continue }
            let start = text.distance(from: text.startIndex, to: swiftRange.lowerBound)
            let end = text.distance(from: text.startIndex, to: swiftRange.upperBound)
            let tokenCharacters = characters[start..<end]
            let kanjiIndices = (start..<end).filter { isKanji(characters[$0]) }
            guard !kanjiIndices.isEmpty else { continue }

            let total = Double(morae(inRomaji: latin))
            let kanaMorae = tokenCharacters.reduce(0.0) { $0 + kanaMora(of: $1) }
            let perKanji = max(1, (total - kanaMorae) / Double(kanjiIndices.count))
            for index in kanjiIndices { result[index] = perKanji }
        }
        return result
    }

    /// 로마자 표기의 모라 수: 모음 = 1, 모음이 뒤따르지 않는 n(ん) = 1, "~tsu"(っ) = 1
    static func morae(inRomaji romaji: String) -> Int {
        let text = Array(romaji.lowercased().replacingOccurrences(of: "~tsu", with: "Q"))
        let vowels: Set<Character> = ["a", "i", "u", "e", "o", "ā", "ī", "ū", "ē", "ō"]
        let longVowels: Set<Character> = ["ā", "ī", "ū", "ē", "ō"]
        var count = 0
        for (index, character) in text.enumerated() {
            if character == "Q" {
                count += 1
            } else if vowels.contains(character) {
                count += longVowels.contains(character) ? 2 : 1
            } else if character == "n" {
                let next = index + 1 < text.count ? text[index + 1] : nil
                if next.map({ !vowels.contains($0) && $0 != "y" }) ?? true { count += 1 }
            }
        }
        return count
    }

    static func isKanji(_ character: Character) -> Bool {
        guard let value = character.unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(value) || (0x3400...0x4DBF).contains(value) || value == 0x3005 // 々
    }

    /// 가나 한 글자의 모라: 작은 ゃゅょぁぃぅぇぉゎ 는 앞 글자와 합쳐 0, 그 외 가나(っ·ー 포함)는 1
    static func kanaMora(of character: Character) -> Double {
        guard let value = character.unicodeScalars.first?.value else { return 0 }
        switch value {
        case 0x3041, 0x3043, 0x3045, 0x3047, 0x3049, 0x3083, 0x3085, 0x3087, 0x308E,
             0x30A1, 0x30A3, 0x30A5, 0x30A7, 0x30A9, 0x30E3, 0x30E5, 0x30E7, 0x30EE:
            return 0
        case 0x3040...0x309F, 0x30A0...0x30FF:
            return 1
        default:
            return 0
        }
    }
}

// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
// ONNX와 분리된 CTC 경로 정렬. IO 콜백이 아닌 별도 학습 작업에서만 사용한다.

import Foundation

struct CTCAlignmentRequest: Sendable {
    let audio: [Float]
    let sampleRate: Double
    /// nil이면 초안용 greedy 전사, 값이 있으면 원문을 보존한 강제 정렬.
    let text: String?
    /// audio[0]이 들리는 곡 시각. 반환 시각도 이 좌표계다.
    let startTime: Double
}

struct CTCAlignmentResult: Sendable {
    let text: String
    let segments: [LyricSegment]
    /// 정렬된 비공백 토큰 프레임 posterior의 기하 평균. 보정된 정확도 확률은 아니다.
    let confidence: Double
    /// 강제 정렬 원문과 독립 greedy 전사의 토큰 편집 유사도. 공백은 제외한다.
    let textMatch: Double
}

enum CTCAlignmentError: LocalizedError, Equatable {
    case invalidAudio, insufficientAudio, invalidVocabulary, invalidShape, nonFinite, tooLong, emptyText
    case unsupportedCharacter(String), impossibleAlignment
    var errorDescription: String? {
        switch self {
        case .invalidAudio: "가사 학습에 사용할 오디오 범위가 올바르지 않습니다."
        case .insufficientAudio: "학습할 보컬이 거의 없는 구간입니다."
        case .invalidVocabulary: "가사 학습 모델의 문자 목록을 읽을 수 없습니다."
        case .invalidShape: "가사 학습 모델의 출력 크기가 예상과 다릅니다."
        case .nonFinite: "가사 학습 입력 또는 출력에 올바르지 않은 수치가 있습니다."
        case .tooLong: "한 번에 학습할 가사나 오디오가 너무 깁니다."
        case .emptyText: "정렬할 가사 문자가 없습니다."
        case let .unsupportedCharacter(character): "학습 모델이 가사 문자 ‘\(character)’를 지원하지 않습니다."
        case .impossibleAlignment: "이 오디오 구간에 가사 전체의 시각을 배치할 수 없습니다."
        }
    }
}

struct CTCVocabulary: Sendable {
    let tokens: [String]
    let blankID: Int
    private let ids: [String: Int]
    private let specialIDs: Set<Int>

    init(contents: String, blankID: Int = 0) throws {
        guard contents.utf8.count <= 262_144 else { throw CTCAlignmentError.invalidVocabulary }
        var entries: [Int: String] = [:]
        var ids: [String: Int] = [:]
        for line in contents.components(separatedBy: .newlines) where !line.isEmpty {
            // Malayalam reph 등 Prepend 문자는 뒤 구분 공백과 한 Character가 된다.
            // 파일 구분자는 ASCII 바이트이므로 Character(" ") 검색으로 토큰을 잃지 않는다.
            let bytes = line.utf8
            guard let separator = bytes.lastIndex(of: 32),
                  let index = Int(String(decoding: bytes[bytes.index(after: separator)...], as: UTF8.self).trimmingCharacters(in: .whitespaces)),
                  index >= 0, index < 16_384 else { throw CTCAlignmentError.invalidVocabulary }
            let token = String(decoding: bytes[..<separator], as: UTF8.self)
            guard !token.isEmpty, entries[index] == nil, ids[token] == nil else { throw CTCAlignmentError.invalidVocabulary }
            entries[index] = token
            ids[token] = index
        }
        guard !entries.isEmpty, entries.count <= 16_384, (0..<entries.count).allSatisfy({ entries[$0] != nil }),
              (0..<entries.count).contains(blankID) else { throw CTCAlignmentError.invalidVocabulary }
        let tokens = (0..<entries.count).map { entries[$0]! }
        self.tokens = tokens
        self.ids = ids
        self.blankID = blankID
        specialIDs = Set(tokens.indices.filter { tokens[$0].hasPrefix("<") && tokens[$0].hasSuffix(">") && tokens[$0].count > 1 })
    }

    func isEmittable(_ token: Int) -> Bool { tokens.indices.contains(token) && token != blankID && !specialIDs.contains(token) }
    func isWhitespace(_ token: Int) -> Bool { tokens[token].allSatisfy { $0.isWhitespace } }

    struct TextToken: Sendable { let id: Int; let character: Int }

    func encode(_ text: String) throws -> [TextToken] {
        guard text.count <= CTCAlignment.maximumCharacters else { throw CTCAlignmentError.tooLong }
        var encoded: [TextToken] = []
        for (index, character) in text.enumerated() {
            if character.isWhitespace {
                if let last = encoded.last, !isWhitespace(last.id), let space = ids[" "] {
                    encoded.append(TextToken(id: space, character: index))
                }
                continue
            }
            let normalized = String(character).lowercased(with: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping
            for scalar in normalized.unicodeScalars {
                if let id = ids[String(scalar)], isEmittable(id) {
                    encoded.append(TextToken(id: id, character: index))
                } else if scalar.properties.isAlphabetic || CharacterSet.decimalDigits.contains(scalar) {
                    // 문장부호는 음가가 없어 생략하되, 모르는 실제 글자를 빼고 성공한 척하지 않는다.
                    throw CTCAlignmentError.unsupportedCharacter(String(character))
                }
            }
        }
        while let last = encoded.last, isWhitespace(last.id) { encoded.removeLast() }
        guard !encoded.isEmpty else { throw CTCAlignmentError.emptyText }
        guard encoded.count <= CTCAlignment.maximumTokens else { throw CTCAlignmentError.tooLong }
        return encoded
    }
}

enum CTCAlignment {
    static let maximumAudioSeconds = 20.0
    static let maximumCharacters = 512
    static let maximumTokens = 1_024
    static let maximumFrames = 1_024
    private static let maximumPathCells = 2_100_000

    private struct TokenRun {
        let id: Int
        var start: Int
        var end: Int
        var logProbability: Double
        var frames: Int
    }

    /// logits는 호출 동안 살아 있는 [T,V] Float32 버퍼. 전체 확률 텐서를 복사하지 않는다.
    static func align(
        logits: UnsafeBufferPointer<Float>, frameCount: Int, vocabulary: CTCVocabulary,
        text: String?, startTime: Double, audioDuration: Double, frameSeconds: Double = 0.02,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws -> CTCAlignmentResult {
        guard frameCount > 0, frameCount <= maximumFrames, vocabulary.tokens.count > 1,
              logits.count == frameCount * vocabulary.tokens.count,
              startTime.isFinite, startTime >= 0, audioDuration.isFinite, audioDuration > 0,
              audioDuration <= maximumAudioSeconds, frameSeconds.isFinite, frameSeconds > 0,
              Double(frameCount - 1) * frameSeconds < audioDuration else { throw CTCAlignmentError.invalidShape }
        let width = vocabulary.tokens.count
        var normalizers = [Double](repeating: 0, count: frameCount)
        var maxima = normalizers
        var greedy: [TokenRun] = []
        var previous = -1
        for frame in 0..<frameCount {
            if isCancelled() { throw CancellationError() }
            let base = frame * width
            var maximum = -Float.infinity
            var best = 0
            for token in 0..<width {
                let value = logits[base + token]
                guard value.isFinite else { throw CTCAlignmentError.nonFinite }
                if value > maximum { maximum = value; best = token }
            }
            var sum = 0.0
            for token in 0..<width { sum += exp(Double(logits[base + token]) - Double(maximum)) }
            let normalizer = log(sum)
            normalizers[frame] = normalizer
            maxima[frame] = Double(maximum)
            if vocabulary.isEmittable(best) {
                let probability = Double(logits[base + best]) - maxima[frame] - normalizer
                if best == previous, !greedy.isEmpty {
                    greedy[greedy.count - 1].end = frame + 1
                    greedy[greedy.count - 1].logProbability += probability
                    greedy[greedy.count - 1].frames += 1
                } else {
                    greedy.append(TokenRun(id: best, start: frame, end: frame + 1, logProbability: probability, frames: 1))
                }
            }
            previous = best
        }
        if isCancelled() { throw CancellationError() }
        guard let text else {
            return transcript(greedy, vocabulary: vocabulary, startTime: startTime, duration: audioDuration, frameSeconds: frameSeconds)
        }
        let encoded = try vocabulary.encode(text)
        let labels = encoded.map { $0.id }
        let repeats = zip(labels, labels.dropFirst()).filter { $0 == $1 }.count
        guard labels.count + repeats <= frameCount else { throw CTCAlignmentError.impossibleAlignment }
        let states = labels.count * 2 + 1
        guard states * frameCount <= maximumPathCells else { throw CTCAlignmentError.tooLong }
        var path = [UInt8](repeating: 255, count: states * frameCount)
        var previousScores = [Double](repeating: -.infinity, count: states)
        var currentScores = previousScores
        func label(_ state: Int) -> Int { state.isMultiple(of: 2) ? vocabulary.blankID : labels[state / 2] }
        previousScores[0] = Double(logits[vocabulary.blankID]) - maxima[0] - normalizers[0]
        previousScores[1] = Double(logits[labels[0]]) - maxima[0] - normalizers[0]
        if frameCount > 1 {
            for frame in 1..<frameCount {
                if isCancelled() { throw CancellationError() }
                for state in 0..<states {
                    var score = previousScores[state]
                    var transition: UInt8 = 0
                    if state > 0, previousScores[state - 1] > score { score = previousScores[state - 1]; transition = 1 }
                    if state > 1, !state.isMultiple(of: 2), label(state) != label(state - 2), previousScores[state - 2] > score {
                        score = previousScores[state - 2]; transition = 2
                    }
                    currentScores[state] = score + (Double(logits[frame * width + label(state)]) - maxima[frame] - normalizers[frame])
                    path[frame * states + state] = transition
                }
                swap(&previousScores, &currentScores)
            }
        }
        var state = previousScores[states - 1] > previousScores[states - 2] ? states - 1 : states - 2
        guard previousScores[state].isFinite else { throw CTCAlignmentError.impossibleAlignment }
        var aligned = labels.map { TokenRun(id: $0, start: frameCount, end: 0, logProbability: 0, frames: 0) }
        for frame in stride(from: frameCount - 1, through: 0, by: -1) {
            if isCancelled() { throw CancellationError() }
            if !state.isMultiple(of: 2) {
                let index = state / 2
                aligned[index].start = min(aligned[index].start, frame)
                aligned[index].end = max(aligned[index].end, frame + 1)
                aligned[index].logProbability += Double(logits[frame * width + labels[index]]) - maxima[frame] - normalizers[frame]
                aligned[index].frames += 1
            }
            if frame > 0 { state -= Int(path[frame * states + state]) }
        }
        guard aligned.allSatisfy({ $0.frames > 0 }) else { throw CTCAlignmentError.impossibleAlignment }
        let mappings = encoded.map { $0.character..<$0.character + 1 }
        return CTCAlignmentResult(text: text,
                                  segments: segments(text: text, runs: aligned, mappings: mappings, vocabulary: vocabulary,
                                                     startTime: startTime, duration: audioDuration, frameSeconds: frameSeconds),
                                  confidence: confidence(aligned, vocabulary: vocabulary),
                                  textMatch: try similarity(labels.filter { !vocabulary.isWhitespace($0) }, greedy.map { $0.id }.filter { !vocabulary.isWhitespace($0) }, isCancelled: isCancelled))
    }

    private static func transcript(_ input: [TokenRun], vocabulary: CTCVocabulary, startTime: Double, duration: Double, frameSeconds: Double) -> CTCAlignmentResult {
        var runs: [TokenRun] = []
        for run in input {
            if vocabulary.isWhitespace(run.id) {
                guard let last = runs.last else { continue }
                if vocabulary.isWhitespace(last.id) { runs[runs.count - 1].end = run.end; continue }
            }
            runs.append(run)
        }
        while let last = runs.last, vocabulary.isWhitespace(last.id) { runs.removeLast() }
        let text = runs.map { vocabulary.tokens[$0.id] }.joined()
        var scalarCharacters: [Int] = []
        for (index, character) in text.enumerated() { scalarCharacters += Array(repeating: index, count: character.unicodeScalars.count) }
        var offset = 0
        let mappings = runs.map { run -> Range<Int> in
            let count = vocabulary.tokens[run.id].unicodeScalars.count
            let range = scalarCharacters[offset]..<scalarCharacters[offset + count - 1] + 1
            offset += count
            return range
        }
        return CTCAlignmentResult(text: text,
                                  segments: segments(text: text, runs: runs, mappings: mappings, vocabulary: vocabulary,
                                                     startTime: startTime, duration: duration, frameSeconds: frameSeconds),
                                  confidence: confidence(runs, vocabulary: vocabulary), textMatch: text.isEmpty ? 0 : 1)
    }

    private static func segments(text: String, runs: [TokenRun], mappings: [Range<Int>], vocabulary: CTCVocabulary,
                                 startTime: Double, duration: Double, frameSeconds: Double) -> [LyricSegment] {
        var result: [LyricSegment] = []
        for (run, range) in zip(runs, mappings) where !vocabulary.isWhitespace(run.id) {
            let start = startTime + min(duration, Double(run.start) * frameSeconds)
            let end = startTime + min(duration, Double(run.end) * frameSeconds)
            if let last = result.last, last.characterStart + last.characterCount > range.lowerBound {
                result[result.count - 1] = LyricSegment(characterStart: last.characterStart,
                    characterCount: max(last.characterStart + last.characterCount, range.upperBound) - last.characterStart,
                    start: last.start, end: end)
            } else {
                result.append(LyricSegment(characterStart: range.lowerBound, characterCount: range.count, start: start, end: end))
            }
        }
        // 음가 없는 문장부호는 인접한 글자와 함께 칠한다. 원문을 정규화/교체하지 않는다.
        let characters = Array(text)
        for index in result.indices {
            let segment = result[index]
            let limit = index + 1 < result.count ? result[index + 1].characterStart : characters.count
            var lower = segment.characterStart
            var upper = lower + segment.characterCount
            if index == 0 { while lower > 0, !characters[lower - 1].isWhitespace { lower -= 1 } }
            while upper < limit, !characters[upper].isWhitespace { upper += 1 }
            result[index] = LyricSegment(characterStart: lower, characterCount: upper - lower, start: segment.start, end: segment.end)
        }
        return result
    }

    private static func confidence(_ runs: [TokenRun], vocabulary: CTCVocabulary) -> Double {
        var total = 0.0
        var frames = 0
        for run in runs where !vocabulary.isWhitespace(run.id) { total += run.logProbability; frames += run.frames }
        return frames == 0 ? 0 : min(1, max(0, exp(total / Double(frames))))
    }

    private static func similarity(_ lhs: [Int], _ rhs: [Int], isCancelled: () -> Bool) throws -> Double {
        guard !lhs.isEmpty || !rhs.isEmpty else { return 1 }
        var previous = Array(0...rhs.count)
        for (i, left) in lhs.enumerated() {
            if isCancelled() { throw CancellationError() }
            var current = [Int](repeating: 0, count: rhs.count + 1)
            current[0] = i + 1
            for (j, right) in rhs.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (left == right ? 0 : 1))
            }
            previous = current
        }
        return max(0, 1 - Double(previous[rhs.count]) / Double(max(lhs.count, rhs.count)))
    }
}

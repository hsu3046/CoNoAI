// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import Foundation
import Testing

struct VocalAudioBufferTests {
    @Test func captureIsOffByDefaultAndTurningOffErasesIt() throws {
        let buffer = VocalAudioBuffer(sampleRate: 10, keepSeconds: 2)
        append(Array(repeating: 1, count: 10), to: buffer, at: 0)
        #expect(buffer.availableRange == nil)
        buffer.setEnabled(true)
        append(Array(repeating: 1, count: 10), to: buffer, at: 20)
        #expect(buffer.availableRange == 2..<3)
        #expect(buffer.snapshot(from: 2, to: 3)?.samples == Array(repeating: 1, count: 10))
        buffer.setEnabled(false)
        #expect(buffer.snapshot(from: 2, to: 3) == nil)
        buffer.setEnabled(true)
        #expect(buffer.availableRange == nil)
    }

    @Test func ringWrapGapAndInvalidSamplesNeverReturnMixedWindows() {
        let buffer = VocalAudioBuffer(sampleRate: 10, keepSeconds: 2)
        buffer.setEnabled(true)
        append((0..<30).map(Float.init), to: buffer, at: 0)
        #expect(buffer.availableRange == 1..<3)
        #expect(buffer.snapshot(from: 1.5, to: 2.5)?.samples == (15..<25).map(Float.init))
        #expect(buffer.snapshot(from: 0.9, to: 2) == nil)
        append([9, 8, 7, 6, 5], to: buffer, at: 40)
        #expect(buffer.availableRange == 4..<4.5)
        #expect(buffer.snapshot(from: 2.5, to: 4.5) == nil)
        append([.nan], to: buffer, at: 45)
        #expect(buffer.availableRange == nil)
        #expect(buffer.snapshot(from: .greatestFiniteMagnitude, to: .infinity) == nil)
        #expect(buffer.snapshot(from: 0, to: 21) == nil)
    }

    @Test func fractionalTwentySecondWindowNeverExceedsTheModelSampleLimit() throws {
        let buffer = VocalAudioBuffer(sampleRate: 44_100)
        buffer.setEnabled(true)
        append(Array(repeating: 0.2, count: 882_002), to: buffer, at: 0)
        let clip = try #require(buffer.snapshot(from: 0.000001, to: 20.000001))
        #expect(clip.samples.count == 882_000)
        #expect(Double(clip.samples.count) / clip.sampleRate <= 20)
        #expect(clip.startTime > 0)
        #expect(abs(clip.startTime - 0.000001) <= 1 / clip.sampleRate)
    }

    private func append(_ samples: [Float], to buffer: VocalAudioBuffer, at frame: Int) {
        samples.withUnsafeBufferPointer { buffer.append(left: $0, right: $0, startFrame: frame) }
    }
}

struct LearnedWordTimingsTests {
    private var identity: WordTimingIdentity { Self.identity() }
    static func identity(text: String = "한글 테스트", model: String = "model-1") -> WordTimingIdentity {
        WordTimingIdentity(track: TrackInfo(id: "one", title: "테스트", artist: "CoNo", album: "", duration: 100),
                           candidateKey: "source:1", lyrics: TimedLyrics(lines: [LyricLine(start: 1, text: text)]), modelVersion: model)
    }
    static var record: LearnedWordTiming {
        LearnedWordTiming(lineIndex: 0, text: "한글 테스트", sourceStart: 1, sourceEnd: 3, timingShift: 0,
                          confidence: 0.8, textMatch: 0.9, segments: [
                            .init(characterStart: 0, characterCount: 2, start: 1.2, end: 1.8),
                            .init(characterStart: 3, characterCount: 3, start: 2, end: 2.8)])
    }

    @Test func identityIncludesExactLyricsAndModelAndOriginalTimingWins() throws {
        #expect(identity.storageKey != Self.identity(text: "다른 테스트").storageKey)
        #expect(identity.storageKey != Self.identity(model: "model-2").storageKey)
        let record = Self.record
        try record.validate()
        #expect(record.applies(to: LyricLine(start: 1, text: record.text), end: 3, shift: 0))
        #expect(!record.applies(to: record.lyricLine, end: 3, shift: 0), "원본에 단어 시각이 있으면 학습값을 적용하지 않는다")
        #expect(!record.applies(to: LyricLine(start: 1, text: record.text), end: 3, shift: 0.1))
        #expect(record.lyricLine.highlightedCharacters(at: 2.4, lineEnd: 3) == 4.5)
    }

    @Test func storeRoundTripPreservesOriginalAndRejectsStaleEpochOrPermit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LearnedWordTimingsStore(directoryURL: directory)
        let initial = try await store.snapshot(for: identity)
        try await store.save(Self.record, for: identity, expectedEpoch: initial.epoch)
        #expect(try await store.load(for: identity)[0] == Self.record)
        try await store.removeAll()
        await #expect(throws: CancellationError.self) {
            try await store.save(Self.record, for: identity, expectedEpoch: initial.epoch)
        }
        let next = try await store.snapshot(for: identity)
        let permit = AlignmentWritePermit()
        permit.revoke()
        await #expect(throws: CancellationError.self) {
            try await store.save(Self.record, for: identity, expectedEpoch: next.epoch, permit: permit)
        }
        #expect(try await store.load(for: identity).isEmpty)
        try await store.save(Self.record, for: identity, expectedEpoch: next.epoch)
        let file = directory.appendingPathComponent(identity.storageKey + ".json")
        let corrupt = Data("bad JSON".utf8)
        try corrupt.write(to: file)
        await #expect(throws: LearnedWordTimingError.self) { try await store.save(Self.record, for: identity) }
        #expect(try Data(contentsOf: file) == corrupt)
    }

    @Test func rejectsPoorConfidenceAndOutOfBoundsCharacterOrTimingData() {
        let r = Self.record
        for (confidence, match, segments) in [
            (0.1, 1.0, r.segments), (1.0, 0.1, r.segments), (.nan, 1.0, r.segments),
            (1.0, 1.0, [.init(characterStart: 500, characterCount: 1, start: 1.1, end: 1.5)]),
            (1.0, 1.0, [.init(characterStart: 0, characterCount: 1, start: 1.5, end: 1.4)])
        ] {
            let invalid = LearnedWordTiming(lineIndex: 0, text: r.text, sourceStart: 1, sourceEnd: 3, timingShift: 0,
                                            confidence: confidence, textMatch: match, segments: segments)
            #expect(throws: LearnedWordTimingError.self) { try invalid.validate() }
        }
    }
}

private actor SuspendedAlignmentInference {
    private var continuation: CheckedContinuation<CTCAlignmentResult, Error>?
    private(set) var calls = 0
    func infer(_ request: CTCAlignmentRequest) async throws -> CTCAlignmentResult {
        calls += 1
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish() {
        let record = LearnedWordTimingsTests.record
        continuation?.resume(returning: CTCAlignmentResult(text: record.text, segments: record.lyricLine.segments, confidence: 0.8, textMatch: 0.9))
        continuation = nil
    }
}

@MainActor struct AlignmentCoordinatorTests {
    @Test(arguments: ["off", "track", "delete", "seek"])
    func cancellationDuringModelLoadOrInferenceNeverAppliesOrStoresOldResult(reason: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "alignment-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let store = LearnedWordTimingsStore(directoryURL: directory)
        let inference = SuspendedAlignmentInference()
        let coordinator = AlignmentCoordinator(modelVersion: "model-1", modelAvailable: true, defaults: defaults, store: store,
                                               inference: { try await inference.infer($0) })
        #expect(!coordinator.isEnabled)
        coordinator.setEnabled(true)
        let buffer = VocalAudioBuffer(sampleRate: 100)
        coordinator.attach(buffer)
        let samples = [Float](repeating: 0.2, count: 400)
        samples.withUnsafeBufferPointer { buffer.append(left: $0, right: $0, startFrame: 0) }
        let identity = LearnedWordTimingsTests.identity()
        coordinator.setContext("track-one", identity: identity)
        try await waitUntil { coordinator.canAutomaticallyLearn }
        let line = LyricLine(start: 1, text: LearnedWordTimingsTests.record.text)
        let window = AlignmentAudioWindow(buffer: buffer, streamStart: 1, streamEnd: 3, songStart: 1)
        coordinator.learn(identity: identity, index: 0, line: line, end: 3, shift: 0, window: window)
        try await waitUntil { await inference.calls == 1 }
        switch reason {
        case "off": coordinator.setEnabled(false)
        case "track": coordinator.setContext("track-two", identity: LearnedWordTimingsTests.identity(text: "다른 곡"))
        case "seek": coordinator.cancel()
        default: await coordinator.removeLearnedTimings()
        }
        #expect(coordinator.isBusy, "native run이 끝나기 전에는 다음 작업을 시작하지 않는다")
        if reason != "delete" { #expect(coordinator.statusText == "현재 분석을 마친 뒤 취소합니다…") }
        coordinator.learn(identity: identity, index: 0, line: line, end: 3, shift: 0, window: window)
        #expect(await inference.calls == 1)
        await inference.finish()
        try await waitUntil { !coordinator.isBusy }
        #expect(coordinator.statusText == (reason == "off" ? "꺼짐" : reason == "delete" ? "학습 기록을 지웠어요" : "재생 구간 대기"))
        #expect(try await store.load(for: identity).isEmpty)
        #expect(coordinator.learnedLine(identity: identity, index: 0, source: line, end: 3, shift: 0) == nil)
    }

    @Test func acceptedResultIsReusedWithoutInferringAgainAndOriginalWordTimingStillWins() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "alignment-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let store = LearnedWordTimingsStore(directoryURL: directory)
        let coordinator = AlignmentCoordinator(modelVersion: "model-1", modelAvailable: true, defaults: defaults, store: store) { _ in
            let record = LearnedWordTimingsTests.record
            return CTCAlignmentResult(text: record.text, segments: record.lyricLine.segments, confidence: 0.8, textMatch: 0.9)
        }
        coordinator.setEnabled(true)
        let buffer = VocalAudioBuffer(sampleRate: 100)
        coordinator.attach(buffer)
        let samples = [Float](repeating: 0.2, count: 400)
        samples.withUnsafeBufferPointer { buffer.append(left: $0, right: $0, startFrame: 0) }
        let identity = LearnedWordTimingsTests.identity()
        let record = LearnedWordTimingsTests.record
        let line = LyricLine(start: 1, text: record.text)
        coordinator.setContext("track-one", identity: identity)
        try await waitUntil { coordinator.canAutomaticallyLearn }
        coordinator.learn(identity: identity, index: 0, line: line, end: 3, shift: 0,
                          window: AlignmentAudioWindow(buffer: buffer, streamStart: 1, streamEnd: 3, songStart: 1))
        try await waitUntil { !coordinator.isBusy }
        #expect(coordinator.learnedLineCount == 1)
        #expect(coordinator.learnedLine(identity: identity, index: 0, source: line, end: 3, shift: 0) == record.lyricLine)
        #expect(!coordinator.needsLine(0, source: line, end: 3, shift: 0))
        #expect(coordinator.learnedLine(identity: identity, index: 0, source: record.lyricLine, end: 3, shift: 0) == nil)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<2_000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("비동기 테스트 조건이 완료되지 않았습니다")
        throw CancellationError()
    }
}

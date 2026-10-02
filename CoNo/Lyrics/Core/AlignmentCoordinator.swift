// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import Foundation
import Observation

struct AlignmentAudioWindow: Sendable {
    let buffer: VocalAudioBuffer
    let streamStart: Double
    let streamEnd: Double
    let songStart: Double
}

enum LocalAlignmentError: LocalizedError {
    case unavailable, busy, missingAudio, unavailableDraft
    var errorDescription: String? {
        switch self {
        case .unavailable: "로컬 가사 학습 모델이 없어요. 모델을 포함해 앱을 다시 빌드해 주세요. 기존 가사는 그대로 사용할 수 있습니다."
        case .busy: "다른 가사 분석이 끝난 뒤 다시 시도해 주세요."
        case .missingAudio: "연속으로 재생한 보컬 구간이 아직 부족해요. AI 반주로 잠시 재생한 뒤 다시 시도해 주세요."
        case .unavailableDraft: "분석할 곡이 바뀌었거나 재생 위치를 옮겼어요. 같은 곡을 연속 재생한 뒤 다시 시도해 주세요."
        }
    }
}

/// 모델 호출·저장을 한 작업으로 직렬화한다. 모델 구현 대신 closure를 받아 취소 경계를 합성 테스트한다.
@MainActor @Observable
final class AlignmentCoordinator {
    typealias Inference = @Sendable (CTCAlignmentRequest) async throws -> CTCAlignmentResult
    static let preferenceKey = "space.knowai.cono.settings.localWordAlignment"
    let modelVersion: String
    let modelAvailable: Bool
    private(set) var isEnabled: Bool
    private(set) var isBusy = false
    private(set) var isDeleting = false
    private(set) var statusText = "꺼짐"
    private(set) var errorMessage: String?
    private(set) var learnedLineCount = 0
    private static let cancellationStatus = "현재 분석을 마친 뒤 취소합니다…"

    @ObservationIgnored private let inference: Inference
    @ObservationIgnored private let releaseModel: @Sendable () async -> Void
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let store: LearnedWordTimingsStore
    @ObservationIgnored private var buffer: VocalAudioBuffer?
    @ObservationIgnored private var gate = AlignmentWorkGate()
    @ObservationIgnored private var cancelActive: (() -> Void)?
    @ObservationIgnored private var activePermit: AlignmentWritePermit?
    @ObservationIgnored private var cacheTask: Task<Void, Never>?
    @ObservationIgnored private var cacheGeneration = UUID()
    @ObservationIgnored private var identity: WordTimingIdentity?
    @ObservationIgnored private var cached: [Int: LearnedWordTiming] = [:]
    @ObservationIgnored private var cachedLines: [Int: LyricLine] = [:]
    @ObservationIgnored private var cacheReady = false
    @ObservationIgnored private var cacheEpoch: UInt64?
    @ObservationIgnored private var cacheFailed = false
    @ObservationIgnored private var attempted: Set<Int> = []
    @ObservationIgnored private var nextAutomaticRun = ContinuousClock.now
    @ObservationIgnored private var manualSessions: Set<UUID> = []

    init(modelVersion: String, modelAvailable: Bool, defaults: UserDefaults = .standard,
         store: LearnedWordTimingsStore = LearnedWordTimingsStore(), releaseModel: @escaping @Sendable () async -> Void = {}, inference: @escaping Inference) {
        self.modelVersion = modelVersion
        self.modelAvailable = modelAvailable
        self.defaults = defaults
        self.store = store
        self.inference = inference
        self.releaseModel = releaseModel
        isEnabled = defaults.bool(forKey: Self.preferenceKey)
        statusText = isEnabled ? "AI 반주 연결 대기" : "꺼짐"
    }

    func setEnabled(_ value: Bool) {
        guard isEnabled != value else { return }
        cancel()
        isEnabled = value
        if !value { cacheGeneration = UUID(); cacheTask?.cancel() }
        defaults.set(value, forKey: Self.preferenceKey)
        buffer?.setEnabled(value)
        if !value { Task(priority: .utility) { await releaseModel() } }
        errorMessage = nil
        statusText = isBusy ? Self.cancellationStatus : waitingStatus
        if value, let identity { loadCache(identity) }
    }

    func attach(_ newBuffer: VocalAudioBuffer?) {
        cancel()
        buffer?.setEnabled(false)
        buffer = newBuffer
        newBuffer?.setEnabled(isEnabled)
        if newBuffer == nil { Task(priority: .utility) { await releaseModel() } }
        statusText = isBusy ? Self.cancellationStatus : waitingStatus
    }

    /// 곡·가사·싱크·재생 구간이 바뀌면 결과 적용과 디스크 저장을 함께 철회한다.
    func setContext(_ context: String, identity next: WordTimingIdentity?) {
        if gate.context != context {
            cancel()
            gate.changeContext(context)
            attempted.removeAll()
        }
        guard identity != next else { return }
        identity = next
        cached.removeAll(); cachedLines.removeAll(); learnedLineCount = 0
        cacheReady = false; cacheFailed = false
        cacheGeneration = UUID()
        cacheTask?.cancel()
        if isEnabled, let next { loadCache(next) }
    }

    func cancel() {
        gate.invalidate()
        activePermit?.revoke()
        cancelActive?()
        statusText = isBusy ? Self.cancellationStatus : waitingStatus
        // 취소한 native run이 돌아올 때까지 isBusy와 gate.active는 유지한다.
    }

    private var waitingStatus: String {
        if !isEnabled { return "꺼짐" }
        if !modelAvailable { return "모델 없음 · 기존 가사 사용" }
        return buffer == nil ? "AI 반주 연결 대기" : "재생 구간 대기"
    }

    private func loadCache(_ identity: WordTimingIdentity) {
        let generation = UUID()
        cacheGeneration = generation
        cacheTask?.cancel()
        cacheReady = false; cacheFailed = false
        cacheTask = Task { [weak self, store] in
            do {
                let snapshot = try await store.snapshot(for: identity)
                guard let self, !Task.isCancelled, self.cacheGeneration == generation,
                      self.identity == identity, self.isEnabled, !self.isDeleting else { return }
                self.cached = snapshot.lines
                self.cachedLines = snapshot.lines.mapValues(\.lyricLine)
                self.learnedLineCount = snapshot.lines.count
                self.cacheEpoch = snapshot.epoch
                self.cacheReady = true
            } catch {
                guard let self, self.cacheGeneration == generation, !Task.isCancelled,
                      self.isEnabled, self.identity == identity, !self.isDeleting else { return }
                self.cacheReady = true
                self.cacheFailed = true
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func learnedLine(identity: WordTimingIdentity, index: Int, source: LyricLine, end: Double, shift: Double) -> LyricLine? {
        guard isEnabled, !isDeleting, self.identity == identity,
              cached[index]?.applies(to: source, end: end, shift: shift) == true else { return nil }
        return cachedLines[index]
    }

    var canAutomaticallyLearn: Bool {
        isEnabled && modelAvailable && buffer != nil && !isBusy && !isDeleting && cacheReady && !cacheFailed
            && manualSessions.isEmpty && ContinuousClock.now >= nextAutomaticRun
    }

    func beginManualSession() -> UUID {
        let token = UUID()
        manualSessions.insert(token)
        cancel()
        return token
    }

    func endManualSession(_ token: UUID) { manualSessions.remove(token) }

    func needsLine(_ index: Int, source: LyricLine, end: Double, shift: Double) -> Bool {
        !attempted.contains(index) && source.segments.isEmpty && !source.isInterlude
            && cached[index]?.applies(to: source, end: end, shift: shift) != true
    }

    func learn(identity: WordTimingIdentity, index: Int, line: LyricLine, end: Double, shift: Double, window: AlignmentAudioWindow) {
        guard canAutomaticallyLearn, self.identity == identity, needsLine(index, source: line, end: end, shift: shift),
              let epoch = cacheEpoch, let ticket = gate.begin() else { return }
        attempted.insert(index)
        let permit = AlignmentWritePermit()
        activePermit = permit
        isBusy = true; errorMessage = nil; statusText = "끝난 줄의 단어 시각 분석 중"
        let began = ContinuousClock.now
        let inference = inference
        let worker = Task.detached(priority: .utility) { try await Self.infer(window, text: line.text, inference: inference) }
        cancelActive = { permit.revoke(); worker.cancel() }
        Task { [weak self, store] in
            guard let self else { return }
            defer { self.finish(ticket, began: began) }
            do {
                let result = try await worker.value
                guard self.accepts(ticket, permit: permit), result.text == line.text else { throw CancellationError() }
                let record = LearnedWordTiming(lineIndex: index, text: line.text, sourceStart: line.start, sourceEnd: end,
                    timingShift: shift, confidence: result.confidence, textMatch: result.textMatch,
                    segments: result.segments.map { .init(characterStart: $0.characterStart, characterCount: $0.characterCount,
                        start: max(line.start, $0.start - shift), end: min(end, ($0.end ?? $0.start) - shift)) })
                try record.validate()
                try await store.save(record, for: identity, expectedEpoch: epoch, permit: permit)
                guard self.accepts(ticket, permit: permit) else { return }
                self.cached[index] = record
                self.cachedLines[index] = record.lyricLine
                self.learnedLineCount = self.cached.count
                self.statusText = "\(self.learnedLineCount)줄 학습됨 · 되감기·다음 재생에 사용"
            } catch is CancellationError {
                // 취소는 기능 해제·곡 전환의 정상 경로다. 새 화면 상태를 덮어쓰지 않는다.
            } catch {
                guard self.accepts(ticket, permit: permit) else { return }
                self.statusText = "이 줄은 기존 가사 표시 유지"
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// 명시적으로 요청한 최근 구간 초안. 자동 학습과 같은 게이트를 사용하며 저장하지 않는다.
    func draft(window: AlignmentAudioWindow, text: String?) async throws -> CTCAlignmentResult {
        guard isEnabled, buffer != nil else { throw LocalAlignmentError.missingAudio }
        guard modelAvailable else { throw LocalAlignmentError.unavailable }
        guard !isDeleting, let ticket = gate.begin() else { throw LocalAlignmentError.busy }
        let permit = AlignmentWritePermit()
        activePermit = permit
        isBusy = true; errorMessage = nil; statusText = text == nil ? "최근 구간 받아쓰기 중" : "최근 구간 줄 시각 분석 중"
        let began = ContinuousClock.now
        let inference = inference
        let worker = Task.detached(priority: .utility) { try await Self.infer(window, text: text, inference: inference) }
        cancelActive = { permit.revoke(); worker.cancel() }
        defer { finish(ticket, began: began) }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: {
                permit.revoke(); worker.cancel()
                Task { @MainActor [weak self] in
                    guard let self, self.gate.accepts(ticket) else { return }
                    self.statusText = Self.cancellationStatus
                }
            })
            guard accepts(ticket, permit: permit) else { throw CancellationError() }
            statusText = "AI 초안 준비됨 · 내용을 확인해 주세요"
            return result
        } catch {
            if accepts(ticket, permit: permit) { errorMessage = error.localizedDescription; statusText = "기존 가사 표시 유지" }
            throw error
        }
    }

    func removeLearnedTimings() async {
        guard !isDeleting else { return }
        cancel()
        isDeleting = true
        cacheGeneration = UUID(); cacheTask?.cancel()
        cached.removeAll(); cachedLines.removeAll(); learnedLineCount = 0
        attempted.removeAll(); cacheReady = false
        defer { isDeleting = false }
        do {
            try await store.removeAll()
            cacheFailed = false
            if let identity { loadCache(identity) }
            errorMessage = nil
            statusText = "학습 기록을 지웠어요"
        } catch { errorMessage = error.localizedDescription; cacheFailed = true }
    }

    private func accepts(_ ticket: AlignmentWorkGate.Ticket, permit: AlignmentWritePermit) -> Bool {
        isEnabled && !isDeleting && gate.accepts(ticket) && permit.isValid
    }

    private func finish(_ ticket: AlignmentWorkGate.Ticket, began: ContinuousClock.Instant) {
        guard gate.active == ticket else { return }
        gate.finish(ticket)
        activePermit = nil; cancelActive = nil; isBusy = false
        if statusText == Self.cancellationStatus { statusText = waitingStatus }
        let elapsed = ContinuousClock.now - began
        let parts = elapsed.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        // 분리 모델과 CPU를 함께 쓰므로 추론 시간의 세 배(최소 5초)는 자동 분석을 쉰다.
        nextAutomaticRun = .now + .seconds(max(5, seconds * 3))
    }

    nonisolated private static func infer(_ window: AlignmentAudioWindow, text: String?, inference: Inference) async throws -> CTCAlignmentResult {
        try Task.checkCancellation()
        guard let clip = window.buffer.snapshot(from: window.streamStart, to: window.streamEnd),
              clip.samples.count >= Int(clip.sampleRate * 0.1) else { throw LocalAlignmentError.missingAudio }
        let songStart = max(0, window.songStart + clip.startTime - window.streamStart)
        try Task.checkCancellation()
        let result = try await inference(.init(audio: clip.samples, sampleRate: clip.sampleRate, text: text, startTime: songStart))
        try Task.checkCancellation()
        return result
    }
}

// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 마이크 채점 (#9): 마이크 → 하이패스 → 16 kHz → SwiftF0(미리 보기 48 ms) → 누설 게이트 → 원곡 음과 비교 → 점수.
// 자기 직렬 큐에서 10 ms 마다 돈다. 음정 검출기는 원곡용과 다른 인스턴스 (모델 객체는 한 스레드만).
//
// 시간축: 마이크 프레임을 "그 순간 귀에 들리던 출력 스트림 위치" 로 옮긴다 — 음정 바·원곡 음정과 같은 축.
//   마이크 샘플의 호스트 시각 H → 들리는 위치 = (지금 들리는 위치) − (지금 − H).
//   재생이 멈췄거나 채우는 중·이동 음소거 중이면 그 구간은 채점하지 않는다.
// 스피커 누설은 DelayPipeline.outputLevels (출력 레벨) 과 LeakageGate 로 거른다.

import Foundation
import Synchronization

/// 지금 귀에 들리는 출력 스트림 위치 (아무 스레드). KaraokeEngine.displayPosition 과 같은 계산.
final class HeardClock: Sendable {
    let pipeline: DelayPipeline
    /// 키 조절 단계 지연 + 화면 싱크 (초) — 엔진이 50 ms 마다 갱신
    private let extraLatencyBits = Atomic<UInt64>(0)

    init(pipeline: DelayPipeline) {
        self.pipeline = pipeline
    }

    func setExtraLatency(_ seconds: Double) {
        extraLatencyBits.store(seconds.bitPattern, ordering: .relaxed)
    }

    /// 재생이 앞으로 가며 소리를 내는 중일 때만
    func advancingPosition() -> Double? {
        guard pipeline.isAdvancing else { return nil }
        return pipeline.playbackPosition().map { $0 - Double(bitPattern: extraLatencyBits.load(ordering: .relaxed)) }
    }
}

final class SingingTracker: @unchecked Sendable {
    /// 마이크 프레임 하나 (16 ms)
    struct Frame: Sendable {
        /// 출력 스트림 초
        let time: Double
        /// 음정 바에 그릴 높이 (MIDI, 원곡 음 옥타브로 접음). 목소리가 아니면 nil
        let midi: Double?
        let hit: Bool
    }

    struct Snapshot: Sendable {
        /// 최근 몇 초의 프레임 (시각 순)
        var frames: [Frame] = []
        var score = SongScore()
        /// 마이크 레벨 (최대 진폭, 0…1)
        var micPeak: Float = 0
        /// 배운 스피커 누설 (dB, 마이크 ÷ 출력). 아직 모르면 nil
        var leakageDB: Double?
        /// 최근 소리 있는 프레임 중 목소리로 인정한 비율
        var acceptedRatio: Double = 0
        var error: String?
    }

    let mic: MicrophoneInput
    private let reference: PitchTimeline
    private let clock: HeardClock
    private let queue = DispatchQueue(label: "space.knowai.cono.singing", qos: .userInitiated)
    private var timer: DispatchSourceTimer?

    // 채점 큐 전용 상태
    private let stream: PitchFrameStream
    private let resampler: AudioResampler?
    private var highPass: HighPassFilter
    private var gate = LeakageGate()
    private var scorer = NoteScorer(start: 0)
    private let segmenter = NoteSegmenter()
    private var micScratch: [Float]
    private var readSamples = 0
    /// 16 kHz 로 넘긴 샘플 수와, 마지막 넘긴 샘플의 들리는 위치 (재생이 멈춰 있었으면 nil)
    private var samples16 = 0
    private var positionAtSamples16: Double?
    /// 16 kHz 프레임별 레벨: levelSums[i] = 프레임 (levelBase + i) 의 제곱합
    private var levelSums: [Double] = []
    private var levelBase = 0
    /// 출력 레벨 기록: (출력 스트림 초, 진폭)
    private var outputHistory: [(time: Double, level: Double)] = []
    private var levelPair = [Float](repeating: 0, count: 2)
    private var frames: [Frame] = []
    private var hitTimes: [Double] = []
    private var lastReferenceMidi: Double?
    private var scoreStartPending = true
    private var lastScoredAt: Double = -1
    private var acceptedHistory: [Bool] = []

    private let keyShiftValue = Atomic<Int>(0)
    private let difficultyValue = Atomic<Int>(SingingJudge.Difficulty.normal.rawValue)
    private let resetRequested = Atomic<Bool>(false)
    private let published = Mutex(Snapshot())

    private static let rate16 = SwiftF0Detector.sampleRate
    private static let hop = 256
    /// 반응 여유: 부른 음을 기준 음 ±80 ms 안에서 찾는다
    private static let matchWindow = 0.08
    /// 원곡 가수가 이만큼 앞뒤로 쉬고 있어야 "쉬는 구간" (누설 학습)
    private static let silentWindow = 0.3
    private static let keepFrameSeconds = 6.0

    init(mic: MicrophoneInput, detector: SwiftF0Detector, reference: PitchTimeline, clock: HeardClock) throws {
        self.mic = mic
        self.reference = reference
        self.clock = clock
        // 실시간 표시용: 미리 보기 3 프레임(48 ms). 10 프레임 대비 유성 판정 99.5%·음정 100% 일치 (2026-09-26 측정)
        stream = PitchFrameStream(estimator: detector, lookaheadFrames: 3)
        resampler = abs(mic.sampleRate - Self.rate16) > 0.5
            ? try AudioResampler(inputRate: mic.sampleRate, outputRate: Self.rate16, channelCount: 1, maxInputFrames: 16_384)
            : nil
        highPass = HighPassFilter(cutoff: 90, sampleRate: mic.sampleRate)
        micScratch = [Float](repeating: 0, count: 16_384)
    }

    var keyShift: Int {
        get { keyShiftValue.load(ordering: .relaxed) }
        set { keyShiftValue.store(newValue, ordering: .relaxed) }
    }

    var difficulty: SingingJudge.Difficulty {
        get { SingingJudge.Difficulty(rawValue: difficultyValue.load(ordering: .relaxed)) ?? .normal }
        set { difficultyValue.store(newValue.rawValue, ordering: .relaxed) }
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    /// 멈추고 지금 돌고 있는 처리가 끝날 때까지 기다린다 (그 뒤엔 검출기를 아무도 안 쓴다)
    func stop() {
        timer?.cancel()
        timer = nil
        queue.sync {}
    }

    /// 새 곡: 점수를 0 부터 (지금 들리는 위치 뒤의 음표만 센다)
    func resetScore() {
        resetRequested.store(true, ordering: .relaxed)
    }

    func snapshot() -> Snapshot {
        published.withLock { $0 }
    }

    // MARK: - 채점 큐

    private func tick() {
        if resetRequested.exchange(false, ordering: .relaxed) {
            scoreStartPending = true
            hitTimes.removeAll()
        }
        drainOutputLevels()

        let available = min(mic.ring.availableToRead, micScratch.count)
        guard available > 0 else { return }
        let read = micScratch.withUnsafeMutableBufferPointer { buffer in
            mic.ring.read(into: buffer.baseAddress!, count: available)
        }
        readSamples += read

        // 이 덩어리 마지막 샘플이 들리던 위치
        let now = mach_absolute_time()
        let endPosition: Double? = mic.hostTime(ofSample: readSamples).flatMap { host in
            clock.advancingPosition().map { $0 - (Double(now) - Double(host)) * DelayPipeline.hostTicksToSeconds }
        }

        var emitted: [PitchFrame] = []
        do {
            try micScratch.withUnsafeMutableBufferPointer { buffer in
                let chunk = UnsafeMutableBufferPointer(rebasing: buffer[0..<read])
                highPass.process(chunk)
                let input = UnsafeBufferPointer(chunk)
                if let resampler {
                    try resampler.process(mono: input) { emitted += push16($0) }
                } else {
                    emitted += push16(input)
                }
            }
        } catch {
            published.withLock { $0.error = error.localizedDescription }
            return
        }
        positionAtSamples16 = endPosition
        judge(emitted)
        publish()
    }

    /// 16 kHz 샘플: 프레임별 레벨을 쌓고 음정 검출기에 넣는다
    private func push16(_ samples: UnsafeBufferPointer<Float>) -> [PitchFrame] {
        for (offset, sample) in samples.enumerated() {
            let frame = (samples16 + offset) / Self.hop - levelBase
            while levelSums.count <= frame { levelSums.append(0) }
            levelSums[frame] += Double(sample * sample)
        }
        samples16 += samples.count
        return stream.push(samples)
    }

    private func drainOutputLevels() {
        levelPair.withUnsafeMutableBufferPointer { pair in
            while clock.pipeline.outputLevels.availableToRead >= 2 {
                clock.pipeline.outputLevels.read(into: pair.baseAddress!, count: 2)
                outputHistory.append((Double(pair[0]), Double(pair[1]).squareRoot()))
            }
        }
        if outputHistory.count > 4_000 { outputHistory.removeFirst(outputHistory.count - 2_000) }
    }

    /// 출력 스트림 시각 t 의 출력 진폭 (가장 가까운 렌더 기록)
    private func outputLevel(at t: Double) -> Double {
        var low = 0
        var high = outputHistory.count
        while low < high {
            let mid = (low + high) / 2
            if outputHistory[mid].time < t { low = mid + 1 } else { high = mid }
        }
        if low < outputHistory.count, low > 0,
           abs(outputHistory[low - 1].time - t) < abs(outputHistory[low].time - t) {
            return outputHistory[low - 1].level
        }
        return low < outputHistory.count ? outputHistory[low].level : (outputHistory.last?.level ?? 0)
    }

    private func judge(_ emitted: [PitchFrame]) {
        guard !emitted.isEmpty else { return }
        defer {
            // 확정된 프레임의 레벨은 버린다
            if let last = emitted.last {
                let drop = min(levelSums.count, last.index + 1 - levelBase)
                if drop > 0 {
                    levelSums.removeFirst(drop)
                    levelBase += drop
                }
            }
        }
        // 재생이 멈춰 있던 덩어리는 채점하지 않는다
        guard let endPosition = positionAtSamples16 else { return }
        func time(of frame: PitchFrame) -> Double {
            endPosition - Double(samples16 - frame.index * Self.hop) / Self.rate16
        }
        let first = time(of: emitted[0])
        let last = time(of: emitted[emitted.count - 1])
        let snapshot = reference.snapshot(from: first - 0.5, to: last + 0.5)
        let referencePitch = ReferencePitch(frames: snapshot.frames, framePeriod: reference.framePeriod, keyShift: keyShift)
        let tolerance = difficulty.tolerance

        if scoreStartPending {
            scorer = NoteScorer(start: first)
            scoreStartPending = false
        }

        for frame in emitted {
            let t = time(of: frame)
            let index = frame.index - levelBase
            let micLevel = index >= 0 && index < levelSums.count ? (levelSums[index] / Double(Self.hop)).squareRoot() : 0
            let output = outputLevel(at: t)
            gate.learn(mic: micLevel, output: output, referenceSilent: !referencePitch.isVoiced(near: t, window: Self.silentWindow))
            let loud = micLevel > gate.minimumLevel
            let accepted = gate.accepts(mic: micLevel, output: output)
            if loud {
                acceptedHistory.append(accepted)
                if acceptedHistory.count > 300 { acceptedHistory.removeFirst(acceptedHistory.count - 300) }
            }

            guard accepted, frame.confidence >= segmenter.voicedThreshold, frame.pitchHz > 0 else {
                frames.append(Frame(time: t, midi: nil, hit: false))
                continue
            }
            let sung = NoteSegmenter.midi(fromHz: frame.pitchHz)
            if let match = referencePitch.nearest(to: sung, at: t, window: Self.matchWindow) {
                lastReferenceMidi = match.reference
                let hit = abs(match.offset) <= tolerance
                frames.append(Frame(time: t, midi: match.reference + match.offset, hit: hit))
                if hit { hitTimes.append(t) }
            } else {
                // 원곡이 쉬는 곳: 최근 원곡 음 옥타브로 접어 그린다 (판정 없음)
                let shown = lastReferenceMidi.map { $0 + SingingJudge.foldedOffset(sung: sung, reference: $0) } ?? sung
                frames.append(Frame(time: t, midi: shown, hit: false))
            }
        }
        if let cutoff = frames.last?.time, frames.count > 1_000 {
            frames.removeAll { $0.time < cutoff - Self.keepFrameSeconds }
        }
        if let cutoff = hitTimes.last, hitTimes.count > 2_000 {
            hitTimes.removeAll { $0 < cutoff - 30 }
        }

        // 음표 채점은 0.25초마다: 최근 12초 음표 중 0.3초 전에 끝난 것 (창 가장자리 1초는 경계가 흔들려 뺀다)
        if last - lastScoredAt >= 0.25 {
            lastScoredAt = last
            let window = reference.snapshot(from: last - 12, to: last)
            let notes = segmenter.segment(window.frames).filter { Double($0.startFrame) * reference.framePeriod >= last - 11 }
            scorer.score(notes: notes, framePeriod: reference.framePeriod, hitTimes: hitTimes, stableUntil: last - 0.3)
        }
    }

    private func publish() {
        let recentStart = (frames.last?.time ?? 0) - Self.keepFrameSeconds
        let recent = frames.drop { $0.time < recentStart }
        let accepted = acceptedHistory.isEmpty ? 0 : Double(acceptedHistory.filter { $0 }.count) / Double(acceptedHistory.count)
        let leakage = gate.leakage.map { 20 * log10(max($0, 1e-6)) }
        let peak = mic.takePeak()
        let score = scorer.score
        published.withLock { snapshot in
            snapshot.frames = Array(recent)
            snapshot.score = score
            snapshot.micPeak = max(peak, snapshot.micPeak * 0.85)
            snapshot.leakageDB = leakage
            snapshot.acceptedRatio = accepted
        }
    }
}

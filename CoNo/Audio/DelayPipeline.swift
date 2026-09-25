// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// 캡처 → (워커 스레드에서 처리·레이트 변환) → N초 지연 재생 파이프라인.
//
//   캡처 IO 스레드 (탭 애그리게이트, 입력 레이트) ──write──▶ captureRing
//        ──▶ 워커 (StreamProcessor: 패스스루 / L−R / AI 분리, 출력 레이트로 변환) ──▶ playbackRing
//   재생 렌더 스레드 (AVAudioSourceNode, 출력 레이트) ◀──read── playbackRing
//        (목표 지연만큼 쌓인 뒤에야 재생 시작 = 프리롤)
//
// 캡처와 재생은 서로 다른 오디오 스레드다. 두 링 버퍼는 각각 생산자·소비자가 하나씩이다.
// 지연(N초)은 보컬 분리 모델이 쓸 계산 시간이자, 다음에 부를 음정을 미리 보여줄 여유다.
// 모든 버퍼는 인터리브 스테레오 Float32.

import AudioToolbox
import Foundation
import Synchronization

/// 시작할 때 고르는 처리 방식 (방식마다 지연이 달라 실행 중에는 바꾸지 않는다)
enum ProcessingMode: Int, CaseIterable, Sendable {
    /// 그대로 통과 (캡처·지연 검증용)
    case passthrough = 0
    /// 고전적인 L−R 센터 캔슬 (AI 없이 비교용)
    case centerCancel = 1
    /// AI 보컬 분리 (MDX-Net)
    case aiSeparation = 2
}

/// 오디오 콜백 하나의 진단값
struct CallbackDiagnostics: Sendable {
    /// 타임스탬프가 연속이 아니었던 횟수 (= 시스템이 제때 IO 를 못 돌림 → 틱 소리)
    var skippedCycles = 0
    /// CoNo 콜백 처리 시간 최대값과 한 주기 길이 (ms)
    var maxCallbackMilliseconds: Double = 0
    var cycleMilliseconds: Double = 0
}

/// UI 표시용 스냅샷.
struct PipelineStats: Sendable {
    var inputPeak: Float = 0
    var outputPeak: Float = 0
    var bufferedSeconds: Double = 0
    var isPrimed = false
    var underruns = 0
    var captureOverflows = 0
    var capturedSeconds: Double = 0
    /// 캡처된 신호가 한 번이라도 무음이 아니었는지 (권한 거부 시 탭은 무음만 준다)
    var hasReceivedSignal = false
    /// 처리 단계에서 난 오류 (나면 워커는 멈추고 무음이 된다)
    var processingError: String?
    var capture = CallbackDiagnostics()
    var playback = CallbackDiagnostics()
}

/// 오디오 콜백 사이클의 연속성·처리 시간 추적. 한 오디오 스레드 전용 상태 + UI 가 읽는 원자값.
private final class CycleMonitor: @unchecked Sendable {
    private let skipCount = Atomic<Int>(0)
    private let maxCallbackTicks = Atomic<UInt64>(0)
    private let cycleFrames = Atomic<Int>(0)
    // 콜백 스레드 전용
    private var lastSampleTime: Double = -1
    private var lastFrames = 0

    /// 샘플 시각이 "직전 시각 + 직전 길이" 와 다르면 사이클을 건너뛴 것.
    /// 0.5초 이상 점프는 재시작으로 보고 세지 않는다.
    func record(sampleTime: Double?, frames: Int, sampleRate: Double) {
        cycleFrames.store(frames, ordering: .relaxed)
        guard let sampleTime else { return }
        if lastSampleTime >= 0 {
            let jump = abs(sampleTime - (lastSampleTime + Double(lastFrames)))
            if jump > 0.5, jump < sampleRate * 0.5 {
                skipCount.add(1, ordering: .relaxed)
            }
        }
        lastSampleTime = sampleTime
        lastFrames = frames
    }

    func recordCallback(ticks: UInt64) {
        if ticks > maxCallbackTicks.load(ordering: .relaxed) {
            maxCallbackTicks.store(ticks, ordering: .relaxed)
        }
    }

    func snapshot(sampleRate: Double, ticksToSeconds: Double) -> CallbackDiagnostics {
        CallbackDiagnostics(
            skippedCycles: skipCount.load(ordering: .relaxed),
            maxCallbackMilliseconds: Double(maxCallbackTicks.load(ordering: .relaxed)) * ticksToSeconds * 1000,
            cycleMilliseconds: sampleRate > 0 ? Double(cycleFrames.load(ordering: .relaxed)) / sampleRate * 1000 : 0
        )
    }
}

final class DelayPipeline: @unchecked Sendable {
    static let channels = 2
    /// 콜백 한 번에 처리할 최대 프레임. 이보다 큰 버퍼는 초과분을 무음 처리한다.
    private static let maxIOFrames = 16_384
    /// 워커가 캡처 링에서 한 번에 꺼내는 프레임 수. 분리기는 내부에서 step 단위로 모아 처리한다.
    private static let workerChunkFrames = 1_024
    static let hostTicksToSeconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()

    /// 캡처(탭) 레이트
    let inputSampleRate: Double
    /// 재생(출력 장치) 레이트 — 재생 시계와 음정 타임라인의 기준
    let outputSampleRate: Double
    let delaySeconds: Double
    private let delaySamples: Int

    private let captureRing: SPSCRingBuffer
    private let playbackRing: SPSCRingBuffer

    // 오디오 스레드별 스크래치 (콜백 안에서 할당하지 않기 위해 미리 확보)
    private let captureScratch: UnsafeMutablePointer<Float>
    private let playScratch: UnsafeMutablePointer<Float>
    // 워커 전용 스크래치
    private let workerScratch: UnsafeMutablePointer<Float>

    /// 재생 스레드만 읽고 쓴다. false 면 playbackRing 이 목표 지연만큼 찰 때까지 무음 출력.
    private var playbackIsPrimed = false
    /// 재생 스레드 전용: 다음 읽기의 앞부분을 페이드인할지 (시작·언더런 뒤 무음에서 소리로 돌아올 때 클릭 방지)
    private var playbackNeedsFadeIn = true
    /// 끊김·재개 페이드 길이 (프레임, 48 kHz 에서 약 1.3 ms)
    private static let edgeFadeFrames = 64
    /// 재생 스레드 전용 누적 재생 프레임 (= 출력 스트림 위치)
    private var playedFrames = 0

    private let processor: StreamProcessor
    /// 진단 녹음 (처리기 입력·출력 최근 30초)
    let recorder: DiagnosticRecorder
    private let isWorkerRunning = Atomic<Bool>(false)
    private var workerThread: Thread?
    /// 워커 루프가 완전히 끝나면 signal (정지 후 같은 분리 모델을 다른 워커가 동시에 쓰지 않도록)
    private let workerExited = DispatchSemaphore(value: 0)

    // 통계 (오디오·워커 스레드가 쓰고 UI 가 읽는다)
    private let inputPeakBits = Atomic<UInt32>(0)
    private let outputPeakBits = Atomic<UInt32>(0)
    private let primedFlag = Atomic<Bool>(false)
    private let underrunCount = Atomic<Int>(0)
    private let overflowCount = Atomic<Int>(0)
    private let capturedFrameCount = Atomic<Int>(0)
    private let receivedSignal = Atomic<Bool>(false)
    private let processingError = Mutex<String?>(nil)
    private let captureMonitor = CycleMonitor()
    private let playbackMonitor = CycleMonitor()

    // 재생 시계 (seqlock): 재생 스레드가 쓰고 UI 가 읽는다. 버전이 홀수면 쓰는 중.
    // clockFrames = 이번 출력 버퍼 앞까지 재생 링에서 실제로 꺼낸 프레임 수
    // clockHostTime = 그 버퍼의 호스트 시각 (mach_absolute_time 단위)
    private let clockVersion = Atomic<Int>(0)
    private let clockFrames = Atomic<Int>(0)
    private let clockHostTime = Atomic<UInt64>(0)

    // 캡처 시계 (seqlock): 캡처 스레드가 쓰고 UI 가 읽는다. 가사 싱크용 (플레이어 재생 위치 ↔ 캡처 스트림 시각).
    private let captureClockVersion = Atomic<Int>(0)
    private let captureClockFrames = Atomic<Int>(0)
    private let captureClockHostTime = Atomic<UInt64>(0)
    /// 캡처 스레드 전용 누적 캡처 프레임
    private var capturedFramesTotal = 0

    /// - Parameter burstSeconds: 처리기가 한 번에 몰아서 내는 최대 길이 (분리기의 최대 대기). 버퍼 여유 계산에 쓴다.
    init(
        inputSampleRate: Double,
        outputSampleRate: Double,
        delaySeconds: Double,
        processor: StreamProcessor,
        burstSeconds: Double = 0
    ) {
        self.inputSampleRate = inputSampleRate
        self.outputSampleRate = outputSampleRate
        self.delaySeconds = delaySeconds
        self.processor = processor
        recorder = DiagnosticRecorder(inputSampleRate: inputSampleRate, outputSampleRate: outputSampleRate)
        delaySamples = Int(delaySeconds * outputSampleRate) * Self.channels

        // 추론 중에도 캡처는 계속 쌓이므로 burst + 4초 여유
        let marginSeconds = burstSeconds + 4
        captureRing = SPSCRingBuffer(capacity: Int(marginSeconds * inputSampleRate) * Self.channels)
        playbackRing = SPSCRingBuffer(capacity: delaySamples + Int(marginSeconds * outputSampleRate) * Self.channels)

        let ioScratchSize = Self.maxIOFrames * Self.channels
        captureScratch = .allocate(capacity: ioScratchSize)
        captureScratch.initialize(repeating: 0, count: ioScratchSize)
        playScratch = .allocate(capacity: ioScratchSize)
        playScratch.initialize(repeating: 0, count: ioScratchSize)

        let workerScratchSize = Self.workerChunkFrames * Self.channels
        workerScratch = .allocate(capacity: workerScratchSize)
        workerScratch.initialize(repeating: 0, count: workerScratchSize)
    }

    deinit {
        stopWorker()
        captureScratch.deallocate()
        playScratch.deallocate()
        workerScratch.deallocate()
    }

    // MARK: - Worker

    func startWorker() {
        guard !isWorkerRunning.exchange(true, ordering: .acquiringAndReleasing) else { return }
        let thread = Thread { [self] in
            runWorkerLoop()
            workerExited.signal()
        }
        thread.name = "CoNo.DelayPipeline.worker"
        thread.qualityOfService = .userInteractive
        workerThread = thread
        thread.start()
    }

    /// 워커를 멈추고, 진행 중인 처리(추론 1회 분량)가 끝날 때까지 최대 5초 기다린다.
    /// false = 시간 안에 안 멈춤 → 워커가 아직 처리기(분리 모델)를 쓰고 있을 수 있다. 호출 쪽이 모델을 재사용하면 안 된다.
    @discardableResult
    func stopWorker() -> Bool {
        isWorkerRunning.store(false, ordering: .releasing)
        guard workerThread != nil else { return true }
        let exited = workerExited.wait(timeout: .now() + 5) == .success
        if !exited {
            processingError.withLock { $0 = "워커 스레드가 5초 안에 멈추지 않았습니다" }
        }
        workerThread = nil
        return exited
    }

    private func runWorkerLoop() {
        let chunkSamples = Self.workerChunkFrames * Self.channels
        while isWorkerRunning.load(ordering: .acquiring) {
            guard captureRing.availableToRead >= chunkSamples else {
                Thread.sleep(forTimeInterval: 0.002)
                continue
            }
            let n = captureRing.read(into: workerScratch, count: chunkSamples)
            recorder.recordInput(UnsafeBufferPointer(start: workerScratch, count: n))
            do {
                try processor.process(UnsafeBufferPointer(start: workerScratch, count: n)) { output in
                    recorder.recordOutput(output)
                    writeToPlayback(output)
                }
            } catch {
                // 처리 실패 시 워커를 멈춘다 → 출력은 언더런으로 무음이 되고 UI 에 사유가 뜬다
                processingError.withLock { $0 = error.localizedDescription }
                isWorkerRunning.store(false, ordering: .releasing)
            }
        }
    }

    /// 재생 링에 전부 쓸 때까지 기다린다 (링이 차 있으면 재생 스레드가 비울 때까지 대기).
    private func writeToPlayback(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress else { return }
        var written = 0
        while written < samples.count, isWorkerRunning.load(ordering: .relaxed) {
            let n = playbackRing.write(base + written, count: samples.count - written)
            written += n
            if n == 0 { Thread.sleep(forTimeInterval: 0.001) }
        }
    }

    // MARK: - 캡처 IO 스레드 (real-time: 할당·락·로그 금지)

    /// 탭 애그리게이트 IOProc 에서 호출.
    /// - Parameters:
    ///   - input: 입력 버퍼 목록. 탭 스트림을 끝에서부터 찾는다 (서브디바이스 입력이 앞에 올 수 있는 구성에도 안전).
    ///   - tapChannelCount: 탭 스트림 채널 수 (스테레오 믹스다운 = 2)
    func renderCapture(input: UnsafePointer<AudioBufferList>, inputTime: UnsafePointer<AudioTimeStamp>, tapChannelCount: Int) {
        let start = mach_absolute_time()
        // 캡처 시계: 이 버퍼 첫 샘플 = 캡처 스트림의 capturedFramesTotal 번째
        let hostTime = inputTime.pointee.mFlags.contains(.hostTimeValid) ? inputTime.pointee.mHostTime : start
        captureClockVersion.add(1, ordering: .acquiringAndReleasing)
        captureClockFrames.store(capturedFramesTotal, ordering: .relaxed)
        captureClockHostTime.store(hostTime, ordering: .relaxed)
        captureClockVersion.add(1, ordering: .acquiringAndReleasing)

        let frames = captureTap(from: input, tapChannelCount: tapChannelCount)
        capturedFramesTotal += frames
        let valid = inputTime.pointee.mFlags.contains(.sampleTimeValid)
        captureMonitor.record(sampleTime: valid ? inputTime.pointee.mSampleTime : nil, frames: frames, sampleRate: inputSampleRate)
        captureMonitor.recordCallback(ticks: mach_absolute_time() &- start)
    }

    /// - Returns: 받은 프레임 수
    private func captureTap(from input: UnsafePointer<AudioBufferList>, tapChannelCount: Int) -> Int {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))

        // 끝에서부터 탭 채널 수만큼의 버퍼를 고른다 (최대 2채널 = 좌/우 소스)
        var leftBase: UnsafePointer<Float>?
        var leftStride = 1
        var rightBase: UnsafePointer<Float>?
        var rightStride = 1
        var frames = Int.max
        var channelsFound = 0
        var index = buffers.count - 1
        while index >= 0, channelsFound < tapChannelCount {
            let buffer = buffers[index]
            let channelCount = Int(buffer.mNumberChannels)
            guard channelCount > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { break }
            frames = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channelCount))
            // 뒤에서부터 채우므로 이 버퍼가 앞쪽 채널
            if channelCount >= 2 {
                leftBase = UnsafePointer(data)
                leftStride = channelCount
                rightBase = UnsafePointer(data + 1)
                rightStride = channelCount
            } else {
                rightBase = leftBase ?? UnsafePointer(data)
                rightStride = leftBase == nil ? 1 : leftStride
                leftBase = UnsafePointer(data)
                leftStride = 1
            }
            channelsFound += channelCount
            index -= 1
        }

        guard let leftBase, frames != Int.max, frames > 0 else { return 0 }
        let right = rightBase ?? leftBase // 모노면 복제
        let frameCount = min(frames, Self.maxIOFrames)

        var peak: Float = 0
        for frame in 0..<frameCount {
            let left = leftBase[frame * leftStride]
            let rightSample = right[frame * rightStride]
            captureScratch[frame * 2] = left
            captureScratch[frame * 2 + 1] = rightSample
            peak = max(peak, abs(left), abs(rightSample))
        }

        let samples = frameCount * Self.channels
        if captureRing.write(captureScratch, count: samples) < samples {
            overflowCount.add(1, ordering: .relaxed)
        }
        capturedFrameCount.add(frameCount, ordering: .relaxed)
        if peak > 0 { receivedSignal.store(true, ordering: .relaxed) }
        Self.raisePeak(inputPeakBits, to: peak)
        return frameCount
    }

    // MARK: - 재생 렌더 스레드 (real-time: 할당·락·로그 금지)

    /// AVAudioSourceNode 렌더 블록에서 호출.
    func renderPlayback(frameCount: Int, output: UnsafeMutablePointer<AudioBufferList>, timestamp: UnsafePointer<AudioTimeStamp>) {
        let start = mach_absolute_time()
        let frames = min(frameCount, Self.maxIOFrames)
        let samples = frames * Self.channels

        // 프리롤: 목표 지연만큼 쌓이기 전엔 무음. 언더런 후에도 다시 목표 지연까지 채운다
        // (지연을 일정하게 유지해야 가사·음정 표시 싱크가 맞는다).
        if !playbackIsPrimed, playbackRing.availableToRead >= delaySamples {
            playbackIsPrimed = true
            primedFlag.store(true, ordering: .relaxed)
        }

        var got = 0
        if playbackIsPrimed {
            got = playbackRing.read(into: playScratch, count: samples)
            if playbackNeedsFadeIn, got > 0 {
                Self.applyEdgeFade(playScratch, frames: got / Self.channels, fadeIn: true)
                playbackNeedsFadeIn = false
            }
            if got < samples {
                // 언더런: 남은 소리 끝을 페이드아웃해 무음으로 뚝 끊기는 클릭을 줄이고, 다시 채워지면 페이드인
                Self.applyEdgeFade(playScratch, frames: got / Self.channels, fadeIn: false)
                playbackNeedsFadeIn = true
                underrunCount.add(1, ordering: .relaxed)
                playbackIsPrimed = false
                primedFlag.store(false, ordering: .relaxed)
            }
        }
        if got < samples {
            (playScratch + got).update(repeating: 0, count: samples - got)
        }

        // 재생 시계 갱신: 이 버퍼 첫 샘플 = 출력 스트림의 playedFrames 번째
        let hostTime = timestamp.pointee.mFlags.contains(.hostTimeValid) ? timestamp.pointee.mHostTime : start
        clockVersion.add(1, ordering: .acquiringAndReleasing)
        clockFrames.store(playedFrames, ordering: .relaxed)
        clockHostTime.store(hostTime, ordering: .relaxed)
        clockVersion.add(1, ordering: .acquiringAndReleasing)
        playedFrames += got / Self.channels

        // 채널별 버퍼(비인터리브)든 인터리브든: 앞의 두 채널에 좌/우, 나머지는 0
        var peak: Float = 0
        var globalChannel = 0
        for buffer in UnsafeMutableAudioBufferListPointer(output) {
            let channelCount = Int(buffer.mNumberChannels)
            guard channelCount > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let bufferFrames = min(Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channelCount), frames)
            for channel in 0..<channelCount {
                let source = globalChannel + channel
                for frame in 0..<bufferFrames {
                    let value: Float = source < Self.channels ? playScratch[frame * 2 + source] : 0
                    data[frame * channelCount + channel] = value
                    peak = max(peak, abs(value))
                }
            }
            globalChannel += channelCount
        }
        Self.raisePeak(outputPeakBits, to: peak)

        let valid = timestamp.pointee.mFlags.contains(.sampleTimeValid)
        playbackMonitor.record(sampleTime: valid ? timestamp.pointee.mSampleTime : nil, frames: frames, sampleRate: outputSampleRate)
        playbackMonitor.recordCallback(ticks: mach_absolute_time() &- start)
    }

    /// 인터리브 스테레오 버퍼의 앞(페이드인) 또는 끝(페이드아웃) 을 선형으로 줄인다. 실시간 안전 (할당 없음).
    private static func applyEdgeFade(_ buffer: UnsafeMutablePointer<Float>, frames: Int, fadeIn: Bool) {
        let length = min(frames, edgeFadeFrames)
        guard length > 0 else { return }
        for i in 0..<length {
            let gain = Float(i + 1) / Float(length + 1)
            let frame = fadeIn ? i : frames - 1 - i
            buffer[frame * channels] *= gain
            buffer[frame * channels + 1] *= gain
        }
    }

    private static func raisePeak(_ atomic: borrowing Atomic<UInt32>, to peak: Float) {
        if peak > Float(bitPattern: atomic.load(ordering: .relaxed)) {
            atomic.store(peak.bitPattern, ordering: .relaxed)
        }
    }

    // MARK: - Playback clock (UI 스레드)

    /// 지금 스피커로 나가고 있는 출력 스트림 위치 (초). 아직 재생 전이면 nil.
    /// 마지막 렌더의 (위치, 호스트 시각) 에서 경과 시간으로 보간하되, 끊김(언더런) 중에 앞으로 달려가지 않도록 +50 ms 로 제한.
    func playbackPosition() -> Double? {
        for _ in 0..<4 {
            let before = clockVersion.load(ordering: .acquiring)
            guard before % 2 == 0 else { continue }
            let frames = clockFrames.load(ordering: .relaxed)
            let hostTime = clockHostTime.load(ordering: .relaxed)
            // seqlock: 데이터 읽기가 두 번째 버전 읽기 뒤로 재배치되지 않게 (ARM64)
            atomicMemoryFence(ordering: .acquiring)
            let after = clockVersion.load(ordering: .acquiring)
            guard before == after else { continue }
            guard hostTime != 0 else { return nil }
            // 렌더 시각은 보통 "곧 재생될" 미래라 경과 시간이 음수일 수 있다
            let now = mach_absolute_time()
            let elapsed = (Double(now) - Double(hostTime)) * Self.hostTicksToSeconds
            return Double(frames) / outputSampleRate + min(max(elapsed, -0.1), 0.05)
        }
        return nil
    }

    /// 호스트 시각 H 에 캡처되던 소리의 캡처 스트림 위치 (초). 마지막 캡처 콜백 기준으로 외삽한다 (제한 없음).
    /// 출력 스트림과의 관계: 패스스루/L−R 은 같은 초, AI 분리는 출력 = 캡처 − rightContext.
    func captureStreamPosition(atHostTime hostTime: UInt64) -> Double? {
        for _ in 0..<4 {
            let before = captureClockVersion.load(ordering: .acquiring)
            guard before % 2 == 0 else { continue }
            let frames = captureClockFrames.load(ordering: .relaxed)
            let anchorHost = captureClockHostTime.load(ordering: .relaxed)
            atomicMemoryFence(ordering: .acquiring)
            let after = captureClockVersion.load(ordering: .acquiring)
            guard before == after else { continue }
            guard anchorHost != 0 else { return nil }
            let elapsed = (Double(hostTime) - Double(anchorHost)) * Self.hostTicksToSeconds
            return Double(frames) / inputSampleRate + elapsed
        }
        return nil
    }

    // MARK: - Stats (UI 스레드)

    /// 피크는 읽으면서 0 으로 리셋한다 (UI 폴링 주기 동안의 최댓값).
    func takeStats() -> PipelineStats {
        PipelineStats(
            inputPeak: Float(bitPattern: inputPeakBits.exchange(0, ordering: .relaxed)),
            outputPeak: Float(bitPattern: outputPeakBits.exchange(0, ordering: .relaxed)),
            bufferedSeconds: Double(playbackRing.availableToRead / Self.channels) / outputSampleRate,
            isPrimed: primedFlag.load(ordering: .relaxed),
            underruns: underrunCount.load(ordering: .relaxed),
            captureOverflows: overflowCount.load(ordering: .relaxed),
            capturedSeconds: Double(capturedFrameCount.load(ordering: .relaxed)) / inputSampleRate,
            hasReceivedSignal: receivedSignal.load(ordering: .relaxed),
            processingError: processingError.withLock { $0 },
            capture: captureMonitor.snapshot(sampleRate: inputSampleRate, ticksToSeconds: Self.hostTicksToSeconds),
            playback: playbackMonitor.snapshot(sampleRate: outputSampleRate, ticksToSeconds: Self.hostTicksToSeconds)
        )
    }
}

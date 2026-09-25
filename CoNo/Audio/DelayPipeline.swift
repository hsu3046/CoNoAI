// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// 캡처 → (워커 스레드에서 처리) → N초 지연 재생 파이프라인.
//
//   IO 스레드 ──write──▶ captureRing ──▶ 워커(StreamProcessor: 패스스루 / L−R / AI 분리) ──▶ playbackRing
//   IO 스레드 ◀──read── playbackRing  (목표 지연만큼 쌓인 뒤에야 재생 시작 = 프리롤)
//
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
}

final class DelayPipeline: @unchecked Sendable {
    static let channels = 2
    /// IO 콜백 한 번에 처리할 최대 프레임. 이보다 큰 IO 버퍼는 초과분을 무음 처리한다.
    private static let maxIOFrames = 16_384
    /// 워커가 캡처 링에서 한 번에 꺼내는 프레임 수. 분리기는 내부에서 step 단위로 모아 처리한다.
    private static let workerChunkFrames = 1_024

    let sampleRate: Double
    let delaySeconds: Double
    private let delaySamples: Int

    private let captureRing: SPSCRingBuffer
    private let playbackRing: SPSCRingBuffer

    // IO 스레드 전용 스크래치 (콜백 안에서 할당하지 않기 위해 미리 확보)
    private let ioCaptureScratch: UnsafeMutablePointer<Float>
    private let ioPlayScratch: UnsafeMutablePointer<Float>
    // 워커 전용 스크래치
    private let workerScratch: UnsafeMutablePointer<Float>

    /// IO 스레드만 읽고 쓴다. false 면 playbackRing 이 목표 지연만큼 찰 때까지 무음 출력.
    private var ioIsPrimed = false

    private let processor: StreamProcessor
    private let isWorkerRunning = Atomic<Bool>(false)
    private var workerThread: Thread?
    /// 워커 루프가 완전히 끝나면 signal (정지 후 같은 분리 모델을 다른 워커가 동시에 쓰지 않도록)
    private let workerExited = DispatchSemaphore(value: 0)

    // 통계 (IO/워커 스레드가 쓰고 UI 가 읽는다)
    private let inputPeakBits = Atomic<UInt32>(0)
    private let outputPeakBits = Atomic<UInt32>(0)
    private let primedFlag = Atomic<Bool>(false)
    private let underrunCount = Atomic<Int>(0)
    private let overflowCount = Atomic<Int>(0)
    private let capturedFrameCount = Atomic<Int>(0)
    private let receivedSignal = Atomic<Bool>(false)
    private let processingError = Mutex<String?>(nil)

    // 재생 시계 (seqlock): IO 스레드가 쓰고 UI 가 읽는다. 버전이 홀수면 쓰는 중.
    // playedFrames = 이번 출력 버퍼 앞까지 재생 링에서 실제로 꺼낸 프레임 수 = 출력 스트림 위치
    // clockHostTime = 그 버퍼 첫 샘플의 출력 호스트 시각 (mach_absolute_time 단위)
    private let clockVersion = Atomic<Int>(0)
    private let clockFrames = Atomic<Int>(0)
    private let clockHostTime = Atomic<UInt64>(0)
    /// IO 스레드 전용 누적 재생 프레임
    private var ioPlayedFrames = 0
    private static let hostTicksToSeconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()

    /// - Parameter burstSeconds: 처리기가 한 번에 몰아서 내는 최대 길이 (분리기의 step). 버퍼 여유 계산에 쓴다.
    init(sampleRate: Double, delaySeconds: Double, processor: StreamProcessor, burstSeconds: Double = 0) {
        self.sampleRate = sampleRate
        self.delaySeconds = delaySeconds
        self.processor = processor
        delaySamples = Int(delaySeconds * sampleRate) * Self.channels

        // 추론 중에도 캡처는 계속 쌓이므로 burst + 4초 여유
        let marginSamples = Int((burstSeconds + 4) * sampleRate) * Self.channels
        captureRing = SPSCRingBuffer(capacity: marginSamples)
        playbackRing = SPSCRingBuffer(capacity: delaySamples + marginSamples)

        let ioScratchSize = Self.maxIOFrames * Self.channels
        ioCaptureScratch = .allocate(capacity: ioScratchSize)
        ioCaptureScratch.initialize(repeating: 0, count: ioScratchSize)
        ioPlayScratch = .allocate(capacity: ioScratchSize)
        ioPlayScratch.initialize(repeating: 0, count: ioScratchSize)

        let workerScratchSize = Self.workerChunkFrames * Self.channels
        workerScratch = .allocate(capacity: workerScratchSize)
        workerScratch.initialize(repeating: 0, count: workerScratchSize)
    }

    deinit {
        stopWorker()
        ioCaptureScratch.deallocate()
        ioPlayScratch.deallocate()
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
    func stopWorker() {
        isWorkerRunning.store(false, ordering: .releasing)
        guard workerThread != nil else { return }
        if workerExited.wait(timeout: .now() + 5) == .timedOut {
            processingError.withLock { $0 = "워커 스레드가 5초 안에 멈추지 않았습니다" }
        }
        workerThread = nil
    }

    private func runWorkerLoop() {
        let chunkSamples = Self.workerChunkFrames * Self.channels
        while isWorkerRunning.load(ordering: .acquiring) {
            guard captureRing.availableToRead >= chunkSamples else {
                Thread.sleep(forTimeInterval: 0.002)
                continue
            }
            let n = captureRing.read(into: workerScratch, count: chunkSamples)
            do {
                try processor.process(UnsafeBufferPointer(start: workerScratch, count: n)) { output in
                    writeToPlayback(output)
                }
            } catch {
                // 처리 실패 시 워커를 멈춘다 → 출력은 언더런으로 무음이 되고 UI 에 사유가 뜬다
                processingError.withLock { $0 = error.localizedDescription }
                isWorkerRunning.store(false, ordering: .releasing)
            }
        }
    }

    /// 재생 링에 전부 쓸 때까지 기다린다 (링이 차 있으면 IO 스레드가 비울 때까지 대기).
    private func writeToPlayback(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress else { return }
        var written = 0
        while written < samples.count, isWorkerRunning.load(ordering: .relaxed) {
            let n = playbackRing.write(base + written, count: samples.count - written)
            written += n
            if n == 0 { Thread.sleep(forTimeInterval: 0.001) }
        }
    }

    // MARK: - IO thread (real-time: 할당·락·로그 금지)

    /// 애그리게이트 디바이스 IOProc 에서 호출.
    /// - Parameters:
    ///   - input: 입력 버퍼 목록. 탭 스트림은 서브디바이스 입력 스트림 **뒤에** 붙으므로 끝에서부터 찾는다.
    ///   - tapChannelCount: 탭 스트림 채널 수 (스테레오 믹스다운 = 2)
    ///   - outputTime: 출력 버퍼가 재생될 시각 (재생 시계용)
    func renderIO(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        outputTime: UnsafePointer<AudioTimeStamp>,
        tapChannelCount: Int
    ) {
        captureTap(from: input, tapChannelCount: tapChannelCount)
        renderPlayback(into: output, outputTime: outputTime)
    }

    private func captureTap(from input: UnsafePointer<AudioBufferList>, tapChannelCount: Int) {
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

        guard let leftBase, frames != Int.max, frames > 0 else { return }
        let right = rightBase ?? leftBase // 모노면 복제
        let frameCount = min(frames, Self.maxIOFrames)

        var peak: Float = 0
        for frame in 0..<frameCount {
            let left = leftBase[frame * leftStride]
            let rightSample = right[frame * rightStride]
            ioCaptureScratch[frame * 2] = left
            ioCaptureScratch[frame * 2 + 1] = rightSample
            peak = max(peak, abs(left), abs(rightSample))
        }

        let samples = frameCount * Self.channels
        if captureRing.write(ioCaptureScratch, count: samples) < samples {
            overflowCount.add(1, ordering: .relaxed)
        }
        capturedFrameCount.add(frameCount, ordering: .relaxed)
        if peak > 0 { receivedSignal.store(true, ordering: .relaxed) }
        Self.raisePeak(inputPeakBits, to: peak)
    }

    private func renderPlayback(into output: UnsafeMutablePointer<AudioBufferList>, outputTime: UnsafePointer<AudioTimeStamp>) {
        let buffers = UnsafeMutableAudioBufferListPointer(output)
        guard let first = buffers.first, first.mNumberChannels > 0 else { return }
        let frames = min(Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels)), Self.maxIOFrames)
        let samples = frames * Self.channels

        // 프리롤: 목표 지연만큼 쌓이기 전엔 무음. 언더런 후에도 다시 목표 지연까지 채운다
        // (지연을 일정하게 유지해야 나중에 가사·음정 표시 싱크가 맞는다).
        if !ioIsPrimed, playbackRing.availableToRead >= delaySamples {
            ioIsPrimed = true
            primedFlag.store(true, ordering: .relaxed)
        }

        var got = 0
        if ioIsPrimed {
            got = playbackRing.read(into: ioPlayScratch, count: samples)
            if got < samples {
                underrunCount.add(1, ordering: .relaxed)
                ioIsPrimed = false
                primedFlag.store(false, ordering: .relaxed)
            }
        }
        if got < samples {
            (ioPlayScratch + got).update(repeating: 0, count: samples - got)
        }

        // 재생 시계 갱신: 이 버퍼 첫 샘플 = 출력 스트림의 ioPlayedFrames 번째
        if outputTime.pointee.mFlags.contains(.hostTimeValid) {
            clockVersion.add(1, ordering: .acquiringAndReleasing)
            clockFrames.store(ioPlayedFrames, ordering: .relaxed)
            clockHostTime.store(outputTime.pointee.mHostTime, ordering: .relaxed)
            clockVersion.add(1, ordering: .acquiringAndReleasing)
        }
        ioPlayedFrames += got / Self.channels

        // 출력 디바이스 채널 중 앞의 두 채널에 좌/우를 쓰고 나머지는 0
        var peak: Float = 0
        var globalChannel = 0
        for buffer in buffers {
            let channelCount = Int(buffer.mNumberChannels)
            guard channelCount > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let bufferFrames = min(Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channelCount), frames)
            for channel in 0..<channelCount {
                let source = globalChannel + channel
                for frame in 0..<bufferFrames {
                    let value: Float = source < Self.channels ? ioPlayScratch[frame * 2 + source] : 0
                    data[frame * channelCount + channel] = value
                    peak = max(peak, abs(value))
                }
            }
            globalChannel += channelCount
        }
        Self.raisePeak(outputPeakBits, to: peak)
    }

    private static func raisePeak(_ atomic: borrowing Atomic<UInt32>, to peak: Float) {
        if peak > Float(bitPattern: atomic.load(ordering: .relaxed)) {
            atomic.store(peak.bitPattern, ordering: .relaxed)
        }
    }

    // MARK: - Playback clock (UI 스레드)

    /// 지금 스피커로 나가고 있는 출력 스트림 위치 (초). 아직 재생 전이면 nil.
    /// 마지막 IO 콜백의 (위치, 출력 시각) 에서 경과 시간으로 보간하되, 끊김(언더런) 중에 앞으로 달려가지 않도록 +50 ms 로 제한.
    func playbackPosition() -> Double? {
        for _ in 0..<4 {
            let before = clockVersion.load(ordering: .acquiring)
            guard before % 2 == 0 else { continue }
            let frames = clockFrames.load(ordering: .relaxed)
            let hostTime = clockHostTime.load(ordering: .relaxed)
            let after = clockVersion.load(ordering: .acquiring)
            guard before == after else { continue }
            guard hostTime != 0 else { return nil }
            // 출력 시각은 보통 "곧 재생될" 미래라 경과 시간이 음수일 수 있다 (그만큼 아직 앞 버퍼가 나가는 중)
            let now = mach_absolute_time()
            let elapsed = (Double(now) - Double(hostTime)) * Self.hostTicksToSeconds
            return Double(frames) / sampleRate + min(max(elapsed, -0.1), 0.05)
        }
        return nil
    }

    // MARK: - Stats (UI 스레드)

    /// 피크는 읽으면서 0 으로 리셋한다 (UI 폴링 주기 동안의 최댓값).
    func takeStats() -> PipelineStats {
        PipelineStats(
            inputPeak: Float(bitPattern: inputPeakBits.exchange(0, ordering: .relaxed)),
            outputPeak: Float(bitPattern: outputPeakBits.exchange(0, ordering: .relaxed)),
            bufferedSeconds: Double(playbackRing.availableToRead / Self.channels) / sampleRate,
            isPrimed: primedFlag.load(ordering: .relaxed),
            underruns: underrunCount.load(ordering: .relaxed),
            captureOverflows: overflowCount.load(ordering: .relaxed),
            capturedSeconds: Double(capturedFrameCount.load(ordering: .relaxed)) / sampleRate,
            hasReceivedSignal: receivedSignal.load(ordering: .relaxed),
            processingError: processingError.withLock { $0 }
        )
    }
}

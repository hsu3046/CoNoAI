// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// 캡처 → (워커 스레드에서 처리) → N초 지연 재생 파이프라인.
//
//   IO 스레드 ──write──▶ captureRing ──▶ 워커(처리: 지금은 패스스루/간이 보컬 제거,
//                                              다음 단계에서 AI 보컬 분리) ──▶ playbackRing
//   IO 스레드 ◀──read── playbackRing  (목표 지연만큼 쌓인 뒤에야 재생 시작 = 프리롤)
//
// 지연(N초)은 보컬 분리 모델이 쓸 계산 시간이자, 다음에 부를 음정을 미리 보여줄 여유다.
// 모든 버퍼는 인터리브 스테레오 Float32.

import AudioToolbox
import Foundation
import Synchronization

/// 워커 스레드가 청크에 적용하는 처리.
enum ProcessingMode: Int, CaseIterable, Sendable {
    /// 그대로 통과 (캡처·지연 검증용)
    case passthrough = 0
    /// 고전적인 L−R 센터 캔슬. 가운데 정위된 보컬이 줄지만 베이스·킥도 같이 빠진다. AI 분리 전의 임시 모드.
    case centerCancel = 1
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
}

final class DelayPipeline: @unchecked Sendable {
    static let channels = 2
    /// IO 콜백 한 번에 처리할 최대 프레임. 이보다 큰 IO 버퍼는 초과분을 무음 처리한다.
    private static let maxIOFrames = 16_384
    /// 워커가 한 번에 처리하는 프레임 수 (보컬 분리 도입 시 모델 청크 크기로 바뀐다).
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

    private let processingModeRaw = Atomic<Int>(ProcessingMode.passthrough.rawValue)
    private let isWorkerRunning = Atomic<Bool>(false)
    private var workerThread: Thread?

    // 통계 (IO/워커 스레드가 쓰고 UI 가 읽는다)
    private let inputPeakBits = Atomic<UInt32>(0)
    private let outputPeakBits = Atomic<UInt32>(0)
    private let primedFlag = Atomic<Bool>(false)
    private let underrunCount = Atomic<Int>(0)
    private let overflowCount = Atomic<Int>(0)
    private let capturedFrameCount = Atomic<Int>(0)
    private let receivedSignal = Atomic<Bool>(false)

    init(sampleRate: Double, delaySeconds: Double) {
        self.sampleRate = sampleRate
        self.delaySeconds = delaySeconds
        delaySamples = Int(delaySeconds * sampleRate) * Self.channels

        let marginSamples = Int(2 * sampleRate) * Self.channels // 2초 여유
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

    var processingMode: ProcessingMode {
        get { ProcessingMode(rawValue: processingModeRaw.load(ordering: .relaxed)) ?? .passthrough }
        set { processingModeRaw.store(newValue.rawValue, ordering: .relaxed) }
    }

    // MARK: - Worker

    func startWorker() {
        guard !isWorkerRunning.exchange(true, ordering: .acquiringAndReleasing) else { return }
        let thread = Thread { [self] in runWorkerLoop() }
        thread.name = "CoNo.DelayPipeline.worker"
        thread.qualityOfService = .userInteractive
        workerThread = thread
        thread.start()
    }

    func stopWorker() {
        isWorkerRunning.store(false, ordering: .releasing)
        workerThread = nil
    }

    private func runWorkerLoop() {
        let chunkSamples = Self.workerChunkFrames * Self.channels
        while isWorkerRunning.load(ordering: .acquiring) {
            // 출력 쪽에 자리가 있고 입력이 한 청크 이상 쌓였을 때만 처리
            let hasInput = captureRing.availableToRead >= chunkSamples
            let hasRoom = playbackRing.capacity - playbackRing.availableToRead >= chunkSamples
            guard hasInput, hasRoom else {
                Thread.sleep(forTimeInterval: 0.002)
                continue
            }

            let n = captureRing.read(into: workerScratch, count: chunkSamples)
            apply(processingMode, to: workerScratch, frameCount: n / Self.channels)
            playbackRing.write(workerScratch, count: n)
        }
    }

    private func apply(_ mode: ProcessingMode, to samples: UnsafeMutablePointer<Float>, frameCount: Int) {
        switch mode {
        case .passthrough:
            return
        case .centerCancel:
            for frame in 0..<frameCount {
                let left = samples[frame * 2]
                let right = samples[frame * 2 + 1]
                let side = (left - right) * 0.7
                samples[frame * 2] = side
                samples[frame * 2 + 1] = side
            }
        }
    }

    // MARK: - IO thread (real-time: 할당·락·로그 금지)

    /// 애그리게이트 디바이스 IOProc 에서 호출.
    /// - Parameters:
    ///   - input: 입력 버퍼 목록. 탭 스트림은 서브디바이스 입력 스트림 **뒤에** 붙으므로 끝에서부터 찾는다.
    ///   - tapChannelCount: 탭 스트림 채널 수 (스테레오 믹스다운 = 2)
    func renderIO(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>, tapChannelCount: Int) {
        captureTap(from: input, tapChannelCount: tapChannelCount)
        renderPlayback(into: output)
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

    private func renderPlayback(into output: UnsafeMutablePointer<AudioBufferList>) {
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
            hasReceivedSignal: receivedSignal.load(ordering: .relaxed)
        )
    }
}

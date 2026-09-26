// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 마이크 입력 (채점용). 받기만 하고 내보내지 않는다 (모니터링 없음 → 하울링 없음).
// 시스템 기본 입력 장치를 쓴다. 반향 제거·자동 게인은 쓰지 않는다 — 말소리용 처리가 노래를 뭉갠다 (#9).
//
// AVAudioSinkNode 는 실시간 오디오 스레드에서 불린다: 할당·락 없이 모노로 섞어 링에 쓰고,
// 버퍼 첫 샘플의 (누적 샘플 번호, 호스트 시각) 을 seqlock 으로 남긴다 → 채점 스레드가 샘플을 시각으로 바꾼다.

import AVFoundation
import CoreAudio
import Synchronization

final class MicrophoneInput: @unchecked Sendable {
    let sampleRate: Double
    let deviceName: String
    /// 블루투스 마이크 — 켜면 같은 이어폰의 소리가 통화 음질로 떨어진다
    let isBluetooth: Bool
    /// 모노 샘플 (약 2초)
    let ring: SPSCRingBuffer

    private let engine = AVAudioEngine()
    private let format: AVAudioFormat
    private var sink: AVAudioSinkNode?
    private var configurationObserver: NSObjectProtocol?

    private static let maxFrames = 8_192
    private let scratch: UnsafeMutablePointer<Float>
    /// IO 스레드 전용: 지금까지 링에 넘긴 샘플 수
    private var writtenSamples = 0

    private let clockVersion = Atomic<UInt64>(0)
    private let clockSample = Atomic<Int>(0)
    private let clockHost = Atomic<UInt64>(0)
    private let peakBits = Atomic<UInt32>(0)

    init() throws {
        format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CoreAudioError("마이크(입력 장치)를 찾지 못했습니다")
        }
        sampleRate = format.sampleRate
        ring = SPSCRingBuffer(capacity: Int(format.sampleRate * 2))
        scratch = .allocate(capacity: Self.maxFrames)
        scratch.initialize(repeating: 0, count: Self.maxFrames)

        let device = engine.inputNode.auAudioUnit.deviceID
        deviceName = (try? device.readString(kAudioObjectPropertyName)) ?? "기본 입력"
        let transport: UInt32 = (try? device.read(kAudioDevicePropertyTransportType, defaultValue: UInt32(0))) ?? 0
        isBluetooth = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    deinit {
        stop()
        scratch.deallocate()
    }

    /// - Parameter onConfigurationChange: 입력 장치가 바뀌어 엔진이 멈췄을 때 (메인 스레드)
    func start(onConfigurationChange: @escaping @Sendable () -> Void) throws {
        let channels = Int(format.channelCount)
        let node = AVAudioSinkNode { [self] timestamp, frameCount, audioBufferList in
            receive(timestamp: timestamp, frames: Int(frameCount), buffers: audioBufferList, channels: channels)
            return noErr
        }
        engine.attach(node)
        engine.connect(engine.inputNode, to: node, format: format)
        sink = node
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { _ in onConfigurationChange() }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw CoreAudioError("마이크를 열지 못했습니다: \(error.localizedDescription)")
        }
    }

    func stop() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        engine.stop()
        if let sink {
            engine.detach(sink)
            self.sink = nil
        }
    }

    /// 누적 샘플 번호 → 호스트 시각 (마지막 버퍼 기준으로 외삽). 아직 받은 게 없으면 nil. 아무 스레드.
    func hostTime(ofSample sample: Int) -> UInt64? {
        for _ in 0..<4 {
            let before = clockVersion.load(ordering: .acquiring)
            guard before % 2 == 0 else { continue }
            let anchorSample = clockSample.load(ordering: .relaxed)
            let anchorHost = clockHost.load(ordering: .relaxed)
            atomicMemoryFence(ordering: .acquiring)
            guard before == clockVersion.load(ordering: .acquiring) else { continue }
            guard anchorHost != 0 else { return nil }
            let seconds = Double(sample - anchorSample) / sampleRate
            let ticks = seconds / DelayPipeline.hostTicksToSeconds
            return UInt64(max(0, Double(anchorHost) + ticks))
        }
        return nil
    }

    /// 마지막으로 읽은 뒤 가장 큰 진폭 (레벨 표시용)
    func takePeak() -> Float {
        Float(bitPattern: peakBits.exchange(0, ordering: .relaxed))
    }

    // MARK: - 실시간 스레드 (할당·락·로그 금지)

    private func receive(timestamp: UnsafePointer<AudioTimeStamp>, frames: Int, buffers: UnsafePointer<AudioBufferList>, channels: Int) {
        let count = min(frames, Self.maxFrames)
        scratch.update(repeating: 0, count: count)
        var sources = 0
        for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffers)) {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let stride = max(1, Int(buffer.mNumberChannels))
            let available = min(count, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * stride))
            for channel in 0..<stride {
                for i in 0..<available { scratch[i] += data[i * stride + channel] }
                sources += 1
            }
        }
        var peak: Float = 0
        if sources > 1 {
            let scale = 1 / Float(sources)
            for i in 0..<count { scratch[i] *= scale }
        }
        for i in 0..<count { peak = max(peak, abs(scratch[i])) }
        if peak > Float(bitPattern: peakBits.load(ordering: .relaxed)) {
            peakBits.store(peak.bitPattern, ordering: .relaxed)
        }

        let host = timestamp.pointee.mFlags.contains(.hostTimeValid) ? timestamp.pointee.mHostTime : mach_absolute_time()
        clockVersion.add(1, ordering: .acquiringAndReleasing)
        clockSample.store(writtenSamples, ordering: .relaxed)
        clockHost.store(host, ordering: .relaxed)
        clockVersion.add(1, ordering: .acquiringAndReleasing)
        // 링이 가득 차면(읽는 쪽이 멈춤) 넘치는 만큼 버린다 — 샘플 번호는 실제로 쓴 만큼만 센다
        writtenSamples += ring.write(scratch, count: count)
    }
}

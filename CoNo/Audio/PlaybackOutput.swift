// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// 기본 출력 장치로 재생 (AVAudioEngine + AVAudioSourceNode).
// 소스 노드를 출력 장치의 하드웨어 레이트로 만들어 믹서가 레이트 변환을 하지 않게 한다.
// 입력(탭) 레이트와 다르면 변환은 워커 스레드에서 CoNo 가 직접 한다 (DelayPipeline).

import AVFoundation
import AudioToolbox

/// 렌더 스레드에서 호출: (프레임 수, 출력 버퍼 목록, 타임스탬프)
typealias PlaybackRenderBlock = @Sendable (Int, UnsafeMutablePointer<AudioBufferList>, UnsafePointer<AudioTimeStamp>) -> Void

final class PlaybackOutput: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var configurationObserver: NSObjectProtocol?

    /// 출력 장치 하드웨어 샘플레이트
    var sampleRate: Double { engine.outputNode.outputFormat(forBus: 0).sampleRate }

    var deviceName: String {
        let deviceID = engine.outputNode.auAudioUnit.deviceID
        return (try? deviceID.readString(kAudioObjectPropertyName)) ?? "기본 출력"
    }

    /// - Parameter onConfigurationChange: 출력 장치가 바뀌거나 포맷이 바뀌어 엔진이 멈췄을 때 (메인 스레드)
    func start(render: @escaping PlaybackRenderBlock, onConfigurationChange: @escaping @Sendable () -> Void) throws {
        let rate = sampleRate
        guard rate > 0, let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else {
            throw CoreAudioError("출력 장치 포맷을 읽지 못했습니다")
        }

        let node = AVAudioSourceNode(format: format) { _, timestamp, frameCount, outputData in
            render(Int(frameCount), outputData, timestamp)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1
        sourceNode = node

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
            throw CoreAudioError("재생 엔진 시작 실패: \(error.localizedDescription)")
        }
    }

    func stop() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        engine.stop()
        if let sourceNode {
            engine.detach(sourceNode)
            self.sourceNode = nil
        }
    }

    deinit {
        stop()
    }
}

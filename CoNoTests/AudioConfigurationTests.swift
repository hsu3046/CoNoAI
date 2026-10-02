// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import Synchronization
import Testing

struct AudioConfigurationTests {
    @Test func queuedCallbackFromOldInputCannotRestartReplacementInput() {
        let previousInput = AudioConfigurationGate()
        let replacementInput = AudioConfigurationGate()
        let restarts = Mutex<[String]>([])
        let oldCallback = previousInput.callback { restarts.withLock { $0.append("old") } }
        oldCallback()
        previousInput.invalidate() // MicrophoneInput.stop은 observer 제거 전에 무효화한다.
        let currentCallback = replacementInput.callback { restarts.withLock { $0.append("replacement") } }
        oldCallback() // removeObserver 이전에 큐에 들어간 실제 등록 콜백을 뒤늦게 전달한다.
        currentCallback()
        #expect(restarts.withLock { $0 } == ["old", "replacement"])
    }

    @Test func restartingSameInputKeepsPreviousRegistrationInvalid() {
        let input = AudioConfigurationGate()
        let callbacks = Mutex<[Int]>([])
        let previousCallback = input.callback { callbacks.withLock { $0.append(1) } }
        input.invalidate()
        let restartedCallback = input.callback { callbacks.withLock { $0.append(2) } }
        previousCallback()
        restartedCallback()
        input.invalidate()
        restartedCallback()
        #expect(callbacks.withLock { $0 } == [2])
    }

    @Test func equalGenerationNumbersCannotCrossInputInstances() {
        let firstInput = AudioConfigurationGate()
        let secondInput = AudioConfigurationGate()
        let firstRegistration = firstInput.activate()
        let secondRegistration = secondInput.activate()
        #expect(firstInput.isCurrent(firstRegistration))
        #expect(secondInput.isCurrent(secondRegistration))
        #expect(!secondInput.isCurrent(firstRegistration))
        #expect(!firstInput.isCurrent(secondRegistration))
    }
}

struct SingingNoticeTests {
    @Test func guideWarningPreservesBluetoothAndFailureMessages() throws {
        let combined = try #require(SingingNotice.message(isListening: true, isBluetooth: true, guideVocalLevel: 0.3))
        #expect(combined.contains("블루투스"))
        #expect(combined.contains("가이드 보컬"))
        #expect(combined.contains("원곡 목소리가 내 노래로 채점"))
        let failure = "마이크 권한이 꺼져 있습니다"
        #expect(SingingNotice.message(failure: failure, isListening: false, isBluetooth: true, guideVocalLevel: 0.3) == failure)
    }

    @Test func guideNoticeOnlyAppearsWhileScoringAndGuideIsAudible() {
        #expect(SingingNotice.message(isListening: false, isBluetooth: false, guideVocalLevel: 0.5) == nil)
        #expect(SingingNotice.message(isListening: true, isBluetooth: false, guideVocalLevel: 0) == nil)
        #expect(SingingNotice.message(isListening: true, isBluetooth: false, guideVocalLevel: 0.1)?.contains("가이드 보컬") == true)
        #expect(SingingNotice.message(isListening: true, isBluetooth: true, guideVocalLevel: 0)?.contains("블루투스") == true)
    }
}

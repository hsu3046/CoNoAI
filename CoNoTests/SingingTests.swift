// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import Foundation
import Testing

// MARK: - 마이크 채점 (#9)

private func hz(midi: Double) -> Double { 440 * pow(2, (midi - 69) / 12) }

/// 프레임 번호 first… 에 음 하나씩 (nil = 무성)
private func referenceFrames(from first: Int, _ midis: [Double?]) -> [PitchFrame] {
    midis.enumerated().map { offset, midi in
        PitchFrame(index: first + offset, pitchHz: midi.map(hz(midi:)) ?? 0, confidence: midi == nil ? 0 : 0.9)
    }
}

struct SingingJudgeTests {
    @Test func foldsOctavesIntoHalfOctaveRange() {
        #expect(SingingJudge.foldedOffset(sung: 60, reference: 72) == 0) // 한 옥타브 아래 = 맞음
        #expect(abs(SingingJudge.foldedOffset(sung: 84.3, reference: 60) - 0.3) < 1e-9)
        #expect(abs(SingingJudge.foldedOffset(sung: 59.6, reference: 72) - -0.4) < 1e-9)
        #expect(SingingJudge.foldedOffset(sung: 66, reference: 60) == -6) // 경계: [-6, 6)
        #expect(SingingJudge.foldedOffset(sung: 53, reference: 60) == 5)
    }

    @Test func nearestReferenceUsesKeyShiftAndReactionWindow() {
        let period = 0.016
        // 프레임 100… : C4 10 프레임, 무성 5, E4 10
        let frames = referenceFrames(from: 100, Array(repeating: 60, count: 10) + Array(repeating: nil, count: 5) + Array(repeating: 64, count: 10))
        let reference = ReferencePitch(frames: frames, framePeriod: period, keyShift: 2)

        // 키 +2 → 기준은 D4(62). 한 옥타브 아래 D3 를 불러도 맞음
        let match = reference.nearest(to: 50, at: 104 * period, window: 0.08)
        #expect(match.map { abs($0.reference - 62) < 1e-6 } == true)
        #expect(match.map { abs($0.offset) < 1e-6 } == true)

        // 무성 구간 한가운데라도 ±80 ms 안에 원곡 음이 있으면 찾는다 (반응 여유)
        #expect(reference.nearest(to: 62, at: 112 * period, window: 0.08) != nil)
        // 창 밖이면 없음
        #expect(reference.nearest(to: 62, at: 200 * period, window: 0.08) == nil)
        #expect(!reference.isVoiced(near: 200 * period, window: 0.3))
        #expect(reference.isVoiced(near: 104 * period, window: 0.01))
    }
}

struct LeakageGateTests {
    @Test func learnsSpeakerBleedAndAcceptsOnlyLouderVoice() {
        var gate = LeakageGate()
        // 원곡이 쉬는 동안: 마이크 = 출력 × 0.1 (스피커 누설)
        for _ in 0..<100 {
            gate.learn(mic: 0.02, output: 0.2, referenceSilent: true)
        }
        #expect(gate.leakage.map { abs($0 - 0.1) < 1e-9 } == true)
        // 노래 구간: 출력 0.3 → 예상 누설 0.03. 누설만 들어오면 거절, 목소리가 2배 넘게 크면 인정
        #expect(!gate.accepts(mic: 0.035, output: 0.3))
        #expect(gate.accepts(mic: 0.2, output: 0.3))
    }

    @Test func headphonesLetQuietVoiceThrough() {
        var gate = LeakageGate()
        // 헤드폰: 원곡이 쉬어도 마이크엔 잡음 바닥만
        for _ in 0..<100 {
            gate.learn(mic: 0.0005, output: 0.2, referenceSilent: true)
        }
        #expect(gate.accepts(mic: 0.01, output: 0.4))
        // 잡음 바닥 근처는 목소리 아님
        #expect(!gate.accepts(mic: 0.001, output: 0.4))
    }

    @Test func noiseFloorIgnoresMusicSoQuietVerseAfterLoudIntroPasses() {
        var gate = LeakageGate()
        // 곡 사이 무음: 마이크 잡음 0.001
        for _ in 0..<50 { gate.learn(mic: 0.001, output: 0.0005, referenceSilent: true) }
        // 큰 전주 10초: 누설 0.1 × 0.5 (잡음 바닥 창을 가득 채울 만큼)
        for _ in 0..<600 { gate.learn(mic: 0.05, output: 0.5, referenceSilent: true) }
        // 조용한 절(출력 0.05, 예상 누설 0.005)에서 작은 목소리 0.03 은 통과해야 한다
        #expect(gate.accepts(mic: 0.03, output: 0.05))
    }

    @Test func occasionalHummingDuringGapsDoesNotInflateLeakage() {
        var gate = LeakageGate()
        for i in 0..<200 {
            // 쉬는 구간의 30% 에 사람이 흥얼거림 (큰 비율)
            gate.learn(mic: i % 10 < 3 ? 0.3 : 0.02, output: 0.2, referenceSilent: true)
        }
        #expect(gate.leakage.map { $0 < 0.2 } == true, "중앙값이라 흥얼거림에 끌려가지 않아야 한다")
    }
}

struct NoteScorerTests {
    private let period = 0.016

    @Test func scoresFinishedNotesOnceWeightedByLength() {
        // 음표 두 개: [100,150) 50 프레임, [160,185) 25 프레임
        let notes = [SungNote(startFrame: 100, endFrame: 150, midi: 60), SungNote(startFrame: 160, endFrame: 185, midi: 62)]
        // 첫 음표는 전부 맞춤, 둘째는 20% 만
        let hits = (100..<150).map { Double($0) * period } + (160..<165).map { Double($0) * period }
        var scorer = NoteScorer(start: 0)
        scorer.score(notes: notes, framePeriod: period, hitTimes: hits, stableUntil: 190 * period)
        #expect(scorer.score.notesTotal == 2)
        #expect(scorer.score.notesHit == 1)
        // 득점 = 50 × 1 + 25 × (0.2 / 0.6) → 58.33 / 75 = 78%
        #expect(scorer.score.score == 78)

        // 같은 음표를 다시 넘겨도 두 번 세지 않는다 (창마다 경계가 조금 달라져도)
        scorer.score(notes: notes + [SungNote(startFrame: 161, endFrame: 184, midi: 62)], framePeriod: period, hitTimes: hits, stableUntil: 190 * period)
        #expect(scorer.score.notesTotal == 2)
    }

    @Test func skipsNotesBeforeMicOnAndUnfinishedNotes() {
        let notes = [
            SungNote(startFrame: 10, endFrame: 40, midi: 60),   // 마이크 켜기 전
            SungNote(startFrame: 100, endFrame: 130, midi: 60),
            SungNote(startFrame: 140, endFrame: 400, midi: 60), // 아직 안 끝남
        ]
        var scorer = NoteScorer(start: 50 * period)
        scorer.score(notes: notes, framePeriod: period, hitTimes: [], stableUntil: 200 * period)
        #expect(scorer.score.notesTotal == 1)
        #expect(scorer.score.score == 0)
    }

    @Test func countsHitsInHalfOpenRange() {
        let times = [0.1, 0.2, 0.2, 0.3, 0.5]
        #expect(NoteScorer.count(times, from: 0.2, to: 0.5) == 3)
        #expect(NoteScorer.count(times, from: 0, to: 0.1) == 0)
        #expect(NoteScorer.count([], from: 0, to: 1) == 0)
    }
}

struct HighPassFilterTests {
    @Test func removesLowRumbleKeepsVoiceBand() {
        let rate = 48_000.0
        func rms(ofSineAt frequency: Double) -> Double {
            var filter = HighPassFilter(cutoff: 90, sampleRate: rate)
            var samples = (0..<48_000).map { Float(sin(2 * Double.pi * frequency * Double($0) / rate)) }
            samples.withUnsafeMutableBufferPointer { filter.process($0) }
            let tail = samples[24_000...] // 과도 응답 뒤
            return (tail.reduce(0) { $0 + Double($1 * $1) } / Double(tail.count)).squareRoot()
        }
        let sineRMS = 1 / 2.0.squareRoot()
        #expect(rms(ofSineAt: 30) < sineRMS * 0.15, "30 Hz 험·킥은 크게 줄어야")
        #expect(rms(ofSineAt: 220) > sineRMS * 0.9, "노래 음역(A3)은 거의 그대로")
    }
}

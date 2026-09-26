// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import Foundation
import Testing

// MARK: - PitchFrameStream (SwiftF0 스트리밍 규칙)

/// 샘플 값 = 스트림 내 절대 샘플 번호. 각 프레임의 "음정" 으로 그 프레임의 절대 번호를 돌려준다.
private final class IndexEchoEstimator: FramePitchEstimating {
    let hop = 4
    /// 호출마다 버퍼 첫 프레임의 절대 번호
    private(set) var bufferStartFrames: [Int] = []

    func estimate(_ audio: UnsafeBufferPointer<Float>) throws -> (pitchHz: [Double], confidence: [Float]) {
        let frames = audio.count / hop
        bufferStartFrames.append(Int(audio[0]) / hop)
        let pitch = (0..<frames).map { Double(Int(audio[$0 * hop]) / hop) }
        return (pitch, [Float](repeating: 1, count: frames))
    }
}

struct PitchFrameStreamTests {
    @Test func emitsContiguousFinalFramesWithContext() {
        let estimator = IndexEchoEstimator()
        let stream = PitchFrameStream(estimator: estimator, lookaheadFrames: 10, leftFrames: 11)
        let total = 4 * 300
        let samples = (0..<total).map { Float($0) }

        var emitted: [PitchFrame] = []
        var offset = 0
        for size in [7, 60, 1, 33, 128, 5, 90] + [Int](repeating: 97, count: 20) {
            let n = min(size, total - offset)
            guard n > 0 else { break }
            let emittedBefore = stream.emittedFrames
            let callsBefore = estimator.bufferStartFrames.count
            emitted += samples[offset..<(offset + n)].withUnsafeBufferPointer { stream.push($0) }
            // 모델에 넘긴 버퍼는 이번에 확정할 첫 프레임 앞 11 프레임 문맥을 포함해야 한다
            if estimator.bufferStartFrames.count > callsBefore, let start = estimator.bufferStartFrames.last {
                #expect(start <= max(0, emittedBefore - 11), "문맥 부족: start=\(start) emitted=\(emittedBefore)")
            }
            offset += n
        }

        // 확정 프레임 = 전체 프레임 − 룩어헤드
        #expect(emitted.count == total / 4 - 10)
        for (i, frame) in emitted.enumerated() {
            #expect(frame.index == i)
            #expect(frame.pitchHz == Double(i), "모델이 본 버퍼 위치와 절대 번호가 어긋남 i=\(i)")
        }
        #expect(estimator.bufferStartFrames.last ?? 0 > 0, "버퍼가 한 번도 잘리지 않았다 (테스트가 트리밍을 검증하지 못함)")
    }

    @Test func failingEstimatorKeepsBufferBoundedAndIndicesContiguous() {
        // 처음 40번은 실패, 그 뒤 회복. 실패 중에도 모델 입력이 길어지지 않고 프레임 번호가 이어져야 한다.
        let estimator = FlakyEstimator(failures: 40)
        let stream = PitchFrameStream(estimator: estimator, lookaheadFrames: 10, leftFrames: 11)
        let total = 4 * 400
        let samples = (0..<total).map { Float($0) }

        var emitted: [PitchFrame] = []
        var sawError = false
        for offset in stride(from: 0, to: total, by: 8) {
            emitted += samples[offset..<(offset + 8)].withUnsafeBufferPointer { stream.push($0) }
            if stream.lastError != nil { sawError = true }
        }

        #expect(sawError)
        #expect(stream.lastError == nil, "회복 후에는 오류가 지워져야 한다")
        // 문맥 11 + 룩어헤드 10 + 이번 입력 2 프레임 남짓 — 실패가 이어져도 이보다 길어지면 안 된다
        #expect(estimator.maxInputFrames <= 11 + 10 + 3, "모델 입력이 커졌다: \(estimator.maxInputFrames) 프레임")
        #expect(emitted.count == total / 4 - 10)
        for (i, frame) in emitted.enumerated() { #expect(frame.index == i) }
        // 실패 구간은 무성, 회복 뒤는 정상 값
        #expect(emitted.prefix(10).allSatisfy { $0.confidence == 0 })
        #expect(emitted.last.map { $0.pitchHz == Double($0.index) && $0.confidence == 1 } == true)
    }
}

/// 처음 몇 번은 실패하고 그 뒤로는 IndexEchoEstimator 처럼 동작한다.
private final class FlakyEstimator: FramePitchEstimating {
    struct Failure: Error {}
    let hop = 4
    private var failuresLeft: Int
    private(set) var maxInputFrames = 0

    init(failures: Int) { failuresLeft = failures }

    func estimate(_ audio: UnsafeBufferPointer<Float>) throws -> (pitchHz: [Double], confidence: [Float]) {
        let frames = audio.count / hop
        maxInputFrames = max(maxInputFrames, frames)
        if failuresLeft > 0 {
            failuresLeft -= 1
            throw Failure()
        }
        let pitch = (0..<frames).map { Double(Int(audio[$0 * hop]) / hop) }
        return (pitch, [Float](repeating: 1, count: frames))
    }
}

// MARK: - NoteSegmenter

struct NoteSegmenterTests {
    private func hz(_ midi: Double) -> Double { 440 * pow(2, (midi - 69) / 12) }

    private func frames(_ spec: [(count: Int, midi: Double?)]) -> [PitchFrame] {
        var result: [PitchFrame] = []
        for part in spec {
            for _ in 0..<part.count {
                let i = result.count
                if let midi = part.midi {
                    // ±0.3 반음 비브라토
                    let vibrato = 0.3 * sin(Double(i) * 0.9)
                    result.append(PitchFrame(index: i, pitchHz: hz(midi + vibrato), confidence: 0.9))
                } else {
                    result.append(PitchFrame(index: i, pitchHz: 0, confidence: 0))
                }
            }
        }
        return result
    }

    @Test func groupsVibratoDropsBlipsAndBridgesDropouts() {
        let input = frames([
            (30, 60),   // C4 + 비브라토
            (5, nil),   // 긴 쉼 → 음표 분리
            (3, 70),    // 3 프레임 튐 → 버림
            (7, 62),
            (1, nil),   // 1 프레임 끊김 → 이어 붙임
            (14, 62),
        ])
        let notes = NoteSegmenter().segment(input)
        #expect(notes == [
            SungNote(startFrame: 0, endFrame: 30, midi: 60),
            SungNote(startFrame: 38, endFrame: 60, midi: 62),
        ])
    }

    @Test func mergesSameNoteAcrossShortGlitch() {
        let input = frames([(10, 62), (3, 64), (10, 62)])
        #expect(NoteSegmenter().segment(input) == [SungNote(startFrame: 0, endFrame: 23, midi: 62)])
    }

    @Test func silenceGivesNoNotes() {
        #expect(NoteSegmenter().segment(frames([(50, nil)])).isEmpty)
    }
}

// MARK: - SmartKey (남자키·여자키)

struct SmartKeyTests {
    private func hz(_ midi: Double) -> Double { 440 * pow(2, (midi - 69) / 12) }

    @Test func foldsOctavesTowardComfortableCenter() {
        // 여자 노래(A4) → 남자키: 한 옥타브 아래로 부른다고 보고 −2 (G3 근처)
        #expect(SmartKey.shift(forMedian: 69, toward: .male) == -2)
        // 여자 노래 → 여자키: E4 로 −5
        #expect(SmartKey.shift(forMedian: 69, toward: .female) == -5)
        // 남자 노래(A3) → 남자키: G3 로 −2
        #expect(SmartKey.shift(forMedian: 57, toward: .male) == -2)
        // 남자 노래 → 여자키: +7 은 범위 밖 → 옥타브를 바꿔 −5
        #expect(SmartKey.shift(forMedian: 57, toward: .female) == -5)
        // 이미 맞으면 원키
        #expect(SmartKey.shift(forMedian: 55.2, toward: .male) == 0)
        // 결과는 항상 −6…+6
        for median in stride(from: 40.0, through: 90.0, by: 0.25) {
            for voice in VoiceType.allCases {
                let key = SmartKey.shift(forMedian: median, toward: voice)
                #expect((-6...6).contains(key))
                // 옥타브 무시 거리가 반음 반 이내로 목표에 닿는다
                let landed = median + Double(key) - voice.comfortableCenter
                let folded = abs(landed - 12 * (landed / 12).rounded())
                #expect(folded <= 0.5 + 1e-9, "median \(median) \(voice) → \(key)")
            }
        }
    }

    @Test func estimateNeedsEnoughVoicedFramesAndUsesMedian() {
        let period = 0.016
        let voicedFor = { (seconds: Double, midi: Double) in
            (0..<Int(seconds / period)).map { PitchFrame(index: $0, pitchHz: self.hz(midi), confidence: 0.9) }
        }
        #expect(SmartKey.estimate(frames: voicedFor(5, 60), framePeriod: period) == nil, "유성 5초는 부족")
        // 무성·저신뢰 프레임은 세지 않는다
        let unvoiced = (0..<2000).map { PitchFrame(index: $0, pitchHz: 0, confidence: 0) }
        #expect(SmartKey.estimate(frames: voicedFor(5, 60) + unvoiced, framePeriod: period) == nil)
        // 중앙값: 짧은 고음 하나가 끌어올리지 않는다
        let frames = voicedFor(8, 60) + voicedFor(4, 72)
        let range = SmartKey.estimate(frames: frames, framePeriod: period)
        #expect(range.map { abs($0.medianMidi - 60) < 0.01 } == true)
        #expect(range.map { abs($0.voicedSeconds - 12) < 0.05 } == true)
    }
}


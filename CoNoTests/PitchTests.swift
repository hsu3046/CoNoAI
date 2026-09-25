// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later

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
    @Test func emitsContiguousFinalFramesWithContext() throws {
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
            emitted += try samples[offset..<(offset + n)].withUnsafeBufferPointer { try stream.push($0) }
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

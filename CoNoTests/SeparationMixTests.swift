// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import Testing

struct SeparationMixTests {
    private func sample(_ mix: inout SeparationMix) -> (Float, Float) {
        mix.next(accompanimentLeft: 0.2, accompanimentRight: -0.4,
                 vocalLeft: -0.6, vocalRight: 0.3,
                 originalLeft: 0.7, originalRight: -0.1)
    }

    @Test func modeSwitchRemovesOneSampleStepAndPreservesStereo() {
        var mix = SeparationMix(sampleRate: 44_100)
        mix.select(.accompaniment, guide: 0)
        var previous = sample(&mix)
        #expect(previous == (0.2, -0.4))
        mix.select(.vocals, guide: 0)
        var largestJump: Float = 0
        for _ in 0..<mix.transitionFrames {
            let next = sample(&mix)
            largestJump = max(largestJump, abs(next.0 - previous.0), abs(next.1 - previous.1))
            previous = next
        }
        // 즉시 선택하던 경로는 좌 0.8·우 0.7 단차. 현재는 882개 샘플로 나눈다.
        #expect(largestJump < 0.001)
        #expect(abs(previous.0 + 0.6) < 0.000001)
        #expect(abs(previous.1 - 0.3) < 0.000001)
    }

    @Test func guideChangesRampAndRepeatedSelectionsDoNotRestartRamp() {
        var mix = SeparationMix(sampleRate: 48_000)
        mix.select(.accompaniment, guide: 0)
        _ = sample(&mix)
        mix.select(.accompaniment, guide: 0.5)
        var final: (Float, Float) = (0, 0)
        for _ in 0..<mix.transitionFrames {
            mix.select(.accompaniment, guide: 0.5)
            final = sample(&mix)
        }
        #expect(abs(final.0 + 0.1) < 0.000001)
        #expect(abs(final.1 + 0.25) < 0.000001)
    }

    @Test func interruptedRampStartsAtCurrentWeightsAndSettlesExactly() {
        var mix = SeparationMix(sampleRate: 1_000)
        mix.select(.accompaniment, guide: 0)
        _ = sample(&mix)
        mix.select(.vocals, guide: 0)
        var previous: (Float, Float) = (0, 0)
        for _ in 0..<10 { previous = sample(&mix) }
        mix.select(.original, guide: 0)
        let first = sample(&mix)
        #expect(abs(first.0 - previous.0) < 0.05)
        var last = first
        for _ in 1..<mix.transitionFrames { last = sample(&mix) }
        #expect(last == (0.7, -0.1))
        #expect(sample(&mix) == last)
    }

    @Test func firstSelectionAndInvalidGuideRemainFinite() {
        var mix = SeparationMix(sampleRate: 44_100)
        mix.select(.original, guide: .nan)
        #expect(sample(&mix) == (0.7, -0.1))
        mix.select(.accompaniment, guide: .nan)
        for _ in 0..<mix.transitionFrames { _ = sample(&mix) }
        #expect(sample(&mix) == (0.2, -0.4))
    }
}

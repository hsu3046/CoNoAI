// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import Foundation

/// 같은 시각으로 정렬된 분리 결과 중 들려줄 소리.
enum SeparationOutput: Int, CaseIterable, Sendable {
    case accompaniment = 0
    case vocals = 1
    case original = 2

    var label: String {
        switch self {
        case .accompaniment: "반주"
        case .vocals: "보컬"
        case .original: "원곡"
        }
    }
}

/// 분리 워커 전용. 모드/가이드 변경을 샘플 경계에서 바로 바꾸면 파형에 단차가 생긴다.
/// 출력 레이트 변환 전에 20 ms 동안 같은 시각의 세 신호를 교차 혼합한다.
struct SeparationMix {
    private struct Weights: Equatable {
        var accompaniment: Float
        var vocals: Float
        var original: Float

        static func target(for output: SeparationOutput, guide: Float) -> Self {
            switch output {
            case .accompaniment: .init(accompaniment: 1, vocals: guide.isFinite ? min(max(guide, 0), 0.5) : 0, original: 0)
            case .vocals: .init(accompaniment: 0, vocals: 1, original: 0)
            case .original: .init(accompaniment: 0, vocals: 0, original: 1)
            }
        }
    }

    let transitionFrames: Int
    private var current: Weights?
    private var target: Weights?
    private var remaining = 0

    init(sampleRate: Double) {
        precondition(sampleRate.isFinite && sampleRate >= 1 && sampleRate <= 768_000)
        transitionFrames = max(1, Int((sampleRate * 0.02).rounded()))
    }

    mutating func select(_ output: SeparationOutput, guide: Float) {
        let next = Weights.target(for: output, guide: guide)
        guard target != next else { return }
        if current == nil {
            // 첫 출력에는 이전 소리가 없으므로 선택한 설정 그대로 시작한다.
            current = next
        } else {
            remaining = transitionFrames
        }
        target = next
    }

    mutating func next(accompanimentLeft: Float, accompanimentRight: Float,
                       vocalLeft: Float, vocalRight: Float,
                       originalLeft: Float, originalRight: Float) -> (Float, Float) {
        guard var weights = current, let target else { return (0, 0) }
        if remaining > 0 {
            let divisor = Float(remaining)
            weights.accompaniment += (target.accompaniment - weights.accompaniment) / divisor
            weights.vocals += (target.vocals - weights.vocals) / divisor
            weights.original += (target.original - weights.original) / divisor
            remaining -= 1
            if remaining == 0 { weights = target }
            current = weights
        }
        return (accompanimentLeft * weights.accompaniment + vocalLeft * weights.vocals + originalLeft * weights.original,
                accompanimentRight * weights.accompaniment + vocalRight * weights.vocals + originalRight * weights.original)
    }
}

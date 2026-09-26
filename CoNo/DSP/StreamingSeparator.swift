// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 고정 길이 창만 받는 분리 모델을 연속 스트림에 쓰기 위한 슬라이딩 윈도우.
//
//   history: [────────── chunkSize (MDX: 약 5.9초) ──────────]
//                                   ↑ 사용 구간 ↑
//            [ 왼쪽 문맥 ][ step(+fade) ][ rightContext ]
//
// step 샘플이 새로 들어올 때마다 창 전체를 분리하고, 창 끝에서 rightContext 앞의 step 구간만 내보낸다.
// → 입력 1 샘플당 출력 1 샘플 (스트림 길이 보존).
//   출력 위치 오프셋 = rightContext, 샘플이 출력되기까지 기다리는 최대 시간 = rightContext + step (+ 추론 시간).
// 이웃 창 사이는 fade 샘플만큼 선형 크로스페이드해서 경계 튐을 없앤다.

import Foundation

/// 고정 길이 창을 받아 반주를 돌려주는 분리기 (모델 래퍼 또는 테스트 대역).
protocol ChunkSeparating: AnyObject {
    /// 한 번에 처리하는 창 길이 (샘플)
    var chunkSize: Int { get }
    /// 창 가장자리에서 결과를 믿을 수 없는 길이 (MDX: n_fft/2). rightContext − fade 가 이 이상이어야 한다.
    var edgeTrim: Int { get }
    func separate(
        left: UnsafeBufferPointer<Float>,
        right: UnsafeBufferPointer<Float>,
        outLeft: UnsafeMutableBufferPointer<Float>,
        outRight: UnsafeMutableBufferPointer<Float>
    ) throws
}

struct StreamingSeparatorSettings: Equatable, Sendable {
    /// 몇 샘플마다 창을 새로 분리할지. 추론 1회 시간보다 길어야 실시간이 유지된다.
    var step: Int
    /// 사용 구간 뒤에 남겨 두는 미래 문맥 (품질 ↑, 지연 ↑)
    var rightContext: Int
    /// 이웃 창 크로스페이드 길이
    var fade: Int
}

/// `emit` 콜백 동안에만 유효한 한 스텝 분량 (각 `step` 샘플).
struct StreamingSeparatorOutput {
    let accompanimentLeft: UnsafeBufferPointer<Float>
    let accompanimentRight: UnsafeBufferPointer<Float>
    /// 같은 시점의 원곡 (반주와 정렬됨 — 보컬 = 원곡 − 반주 × 보정계수)
    let mixLeft: UnsafeBufferPointer<Float>
    let mixRight: UnsafeBufferPointer<Float>
}

enum StreamingSeparatorError: LocalizedError {
    case invalidSettings(String)

    var errorDescription: String? {
        switch self {
        case let .invalidSettings(message): "분리 설정이 잘못됐습니다: \(message)"
        }
    }
}

final class StreamingSeparator {
    let settings: StreamingSeparatorSettings
    private let separator: ChunkSeparating
    private let chunkSize: Int

    private var historyLeft: [Float]
    private var historyRight: [Float]
    private var stagingLeft: [Float]
    private var stagingRight: [Float]
    private var stagedCount = 0

    private var separatedLeft: [Float]
    private var separatedRight: [Float]
    private var emitLeft: [Float]
    private var emitRight: [Float]
    private var tailLeft: [Float]
    private var tailRight: [Float]

    /// 출력 스트림의 위치 오프셋: 출력 o 번째 샘플 = 입력 (o − streamOffset) 번째 샘플.
    /// 가사·음정 싱크는 이 값(과 프리롤)으로 맞춘다.
    var streamOffsetSamples: Int { settings.rightContext }

    /// 입력 샘플이 출력되기까지 기다리는 최대 길이 (추론 시간 제외). 프리롤은 이것 + 추론 시간보다 길어야 한다.
    var maxWaitSamples: Int { settings.rightContext + settings.step }

    init(separator: ChunkSeparating, settings: StreamingSeparatorSettings) throws {
        let chunk = separator.chunkSize
        guard settings.step > 0, settings.fade >= 0 else {
            throw StreamingSeparatorError.invalidSettings("step 은 0보다 커야 합니다")
        }
        guard settings.fade <= settings.step else {
            throw StreamingSeparatorError.invalidSettings("fade 는 step 이하여야 합니다")
        }
        guard settings.rightContext - settings.fade >= separator.edgeTrim else {
            throw StreamingSeparatorError.invalidSettings("rightContext − fade 가 가장자리 \(separator.edgeTrim) 샘플보다 짧습니다")
        }
        guard settings.rightContext + settings.step + settings.fade <= chunk else {
            throw StreamingSeparatorError.invalidSettings("step + rightContext 가 창 길이 \(chunk) 를 넘습니다")
        }

        self.separator = separator
        self.settings = settings
        chunkSize = chunk
        historyLeft = [Float](repeating: 0, count: chunk)
        historyRight = historyLeft
        separatedLeft = historyLeft
        separatedRight = historyLeft
        stagingLeft = [Float](repeating: 0, count: settings.step)
        stagingRight = stagingLeft
        emitLeft = stagingLeft
        emitRight = stagingLeft
        tailLeft = [Float](repeating: 0, count: settings.fade)
        tailRight = tailLeft
    }

    /// 플래너 스테레오 입력을 밀어 넣는다. `step` 이 찰 때마다 추론 1회 + `emit` 1회 (같은 스레드에서 동기 호출).
    func push(
        left: UnsafeBufferPointer<Float>,
        right: UnsafeBufferPointer<Float>,
        emit: (StreamingSeparatorOutput) -> Void
    ) throws {
        precondition(left.count == right.count)
        var consumed = 0
        while consumed < left.count {
            let n = min(settings.step - stagedCount, left.count - consumed)
            for i in 0..<n {
                stagingLeft[stagedCount + i] = left[consumed + i]
                stagingRight[stagedCount + i] = right[consumed + i]
            }
            stagedCount += n
            consumed += n
            if stagedCount == settings.step {
                try runStep(emit: emit)
                stagedCount = 0
            }
        }
    }

    private func runStep(emit: (StreamingSeparatorOutput) -> Void) throws {
        let step = settings.step
        let fade = settings.fade

        // 창을 step 만큼 밀고 새 샘플을 끝에 붙인다
        Self.shiftAppend(&historyLeft, stagingLeft)
        Self.shiftAppend(&historyRight, stagingRight)

        try historyLeft.withUnsafeBufferPointer { inL in
            try historyRight.withUnsafeBufferPointer { inR in
                try separatedLeft.withUnsafeMutableBufferPointer { outL in
                    try separatedRight.withUnsafeMutableBufferPointer { outR in
                        try separator.separate(left: inL, right: inR, outLeft: outL, outRight: outR)
                    }
                }
            }
        }

        let start = chunkSize - settings.rightContext - step
        // 앞 fade 구간은 이전 창의 꼬리와 선형 크로스페이드
        for i in 0..<step {
            var l = separatedLeft[start + i]
            var r = separatedRight[start + i]
            if i < fade {
                let a = (Float(i) + 0.5) / Float(fade)
                l = tailLeft[i] * (1 - a) + l * a
                r = tailRight[i] * (1 - a) + r * a
            }
            emitLeft[i] = l
            emitRight[i] = r
        }
        // 다음 창과 겹칠 꼬리 저장 (이번 사용 구간 바로 뒤)
        for i in 0..<fade {
            tailLeft[i] = separatedLeft[start + step + i]
            tailRight[i] = separatedRight[start + step + i]
        }

        emitLeft.withUnsafeBufferPointer { accL in
            emitRight.withUnsafeBufferPointer { accR in
                historyLeft.withUnsafeBufferPointer { mixL in
                    historyRight.withUnsafeBufferPointer { mixR in
                        emit(StreamingSeparatorOutput(
                            accompanimentLeft: accL,
                            accompanimentRight: accR,
                            mixLeft: UnsafeBufferPointer(rebasing: mixL[start..<(start + step)]),
                            mixRight: UnsafeBufferPointer(rebasing: mixR[start..<(start + step)])
                        ))
                    }
                }
            }
        }
    }

    private static func shiftAppend(_ history: inout [Float], _ newSamples: [Float]) {
        let keep = history.count - newSamples.count
        history.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            base.update(from: base + newSamples.count, count: keep)
            newSamples.withUnsafeBufferPointer { src in
                (base + keep).update(from: src.baseAddress!, count: newSamples.count)
            }
        }
    }
}

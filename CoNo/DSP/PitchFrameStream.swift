// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// 프레임 단위 음정 검출기(SwiftF0)를 연속 스트림에 쓰기 위한 버퍼 관리.
// lars76/swift-f0 (MIT) 의 PitchStream._emit 과 같은 규칙:
//   - 모델은 버퍼 전체를 받아 256 샘플(16 kHz 에서 16 ms)마다 프레임을 낸다
//   - 한 프레임은 뒤에 lookaheadFrames(10) 개 프레임이 더 있어야 확정된다
//   - 확정된 프레임 앞쪽 leftFrames(11) 개는 문맥으로 버퍼에 남겨 배치 결과와 같게 만든다

import Foundation

/// 버퍼 전체를 받아 프레임별 (음정 Hz, 신뢰도) 를 돌려주는 검출기.
protocol FramePitchEstimating: AnyObject {
    var hop: Int { get }
    func estimate(_ audio: UnsafeBufferPointer<Float>) throws -> (pitchHz: [Double], confidence: [Float])
}

struct PitchFrame: Equatable, Sendable {
    /// 스트림 시작부터 프레임 번호
    let index: Int
    let pitchHz: Double
    let confidence: Float
}

final class PitchFrameStream {
    let lookaheadFrames: Int
    let leftFrames: Int
    private let estimator: FramePitchEstimating
    private var buffer: [Float] = []
    /// buffer[0] 의 스트림 내 프레임 번호
    private var baseFrame = 0
    /// 지금까지 확정해 내보낸 프레임 수
    private(set) var emittedFrames = 0

    init(estimator: FramePitchEstimating, lookaheadFrames: Int = 10, leftFrames: Int = 11) {
        self.estimator = estimator
        self.lookaheadFrames = lookaheadFrames
        self.leftFrames = leftFrames
    }

    /// 16 kHz 모노 샘플을 추가하고 새로 확정된 프레임을 돌려준다.
    func push(_ samples: UnsafeBufferPointer<Float>) throws -> [PitchFrame] {
        buffer.append(contentsOf: samples)
        let hop = estimator.hop
        let first = emittedFrames - baseFrame
        let available = buffer.count / hop
        let last = available - lookaheadFrames
        guard last > first else { return [] }

        let (pitch, confidence) = try buffer.withUnsafeBufferPointer { try estimator.estimate($0) }
        let usable = min(last, pitch.count, confidence.count)
        guard usable > first else { return [] }

        var frames: [PitchFrame] = []
        frames.reserveCapacity(usable - first)
        for i in first..<usable {
            frames.append(PitchFrame(index: baseFrame + i, pitchHz: pitch[i], confidence: confidence[i]))
        }
        emittedFrames += frames.count

        // 확정된 프레임 앞 leftFrames 개만 남기고 버린다
        let keep = max(0, emittedFrames - leftFrames) - baseFrame
        if keep > 0 {
            buffer.removeFirst(keep * hop)
            baseFrame += keep
        }
        return frames
    }
}

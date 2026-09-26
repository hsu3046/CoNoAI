// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
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
    /// 마지막 push 의 검출 실패 (성공하면 nil)
    private(set) var lastError: Error?

    init(estimator: FramePitchEstimating, lookaheadFrames: Int = 10, leftFrames: Int = 11) {
        self.estimator = estimator
        self.lookaheadFrames = lookaheadFrames
        self.leftFrames = leftFrames
    }

    /// 16 kHz 모노 샘플을 추가하고 새로 확정된 프레임을 돌려준다.
    /// 검출이 실패하면 그 프레임들을 무성으로 채우고 `lastError` 에 남긴다 (던지지 않는다):
    ///   - 던지면 아래 버퍼 정리를 건너뛰어, 실패가 이어질수록 모델 입력이 끝없이 길어진다 (워커가 느려져 분리까지 끊김)
    ///   - 프레임 번호는 빈틈없이 이어져야 한다 (PitchTimeline.snapshot 이 번호 = 배열 위치로 자른다)
    func push(_ samples: UnsafeBufferPointer<Float>) -> [PitchFrame] {
        buffer.append(contentsOf: samples)
        let hop = estimator.hop
        let first = emittedFrames - baseFrame
        let available = buffer.count / hop
        let last = available - lookaheadFrames
        guard last > first else { return [] }

        var frames: [PitchFrame] = []
        frames.reserveCapacity(last - first)
        do {
            let (pitch, confidence) = try buffer.withUnsafeBufferPointer { try estimator.estimate($0) }
            let usable = min(last, pitch.count, confidence.count)
            guard usable > first else { throw PitchStreamError.tooFewFrames(expected: last, got: min(pitch.count, confidence.count)) }
            for i in first..<usable {
                frames.append(PitchFrame(index: baseFrame + i, pitchHz: pitch[i], confidence: confidence[i]))
            }
            lastError = nil
        } catch {
            for i in first..<last {
                frames.append(PitchFrame(index: baseFrame + i, pitchHz: 0, confidence: 0))
            }
            lastError = error
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

enum PitchStreamError: LocalizedError {
    case tooFewFrames(expected: Int, got: Int)

    var errorDescription: String? {
        switch self {
        case let .tooFewFrames(expected, got): "음정 검출기 출력 프레임이 모자랍니다 (필요 \(expected), 받음 \(got))"
        }
    }
}

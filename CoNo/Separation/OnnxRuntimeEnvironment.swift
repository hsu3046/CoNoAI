// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 프로세스 전체에서 하나만 쓰는 ONNX Runtime 환경 (여러 모델이 공유).

import Foundation
import OnnxRuntimeBindings

enum OnnxRuntimeEnvironment {
    /// CONO_ORT_VERBOSE=1 이면 CoreML 이 가져간 노드 수 등 진단 로그를 stderr 로 낸다
    static let shared: Result<ORTEnv, Error> = Result {
        let verbose = ProcessInfo.processInfo.environment["CONO_ORT_VERBOSE"] == "1"
        return try ORTEnv(loggingLevel: verbose ? .verbose : .warning)
    }

    static func env() throws -> ORTEnv {
        try shared.get()
    }
}

extension ORTEnv: @retroactive @unchecked Sendable {}

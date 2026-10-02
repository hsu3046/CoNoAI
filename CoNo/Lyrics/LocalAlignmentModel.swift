// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import Foundation

/// ONNX 초기화·파일 검증도 MainActor 밖에서 한다. 요청은 Coordinator가 항상 한 개로 제한한다.
actor LocalAlignmentModel {
    private var model: OmniASRCTC?

    func unload() { model = nil }

    func infer(_ request: CTCAlignmentRequest) async throws -> CTCAlignmentResult {
        try Task.checkCancellation()
        if model == nil {
            guard let directory = OmniASRCTC.bundledModelDirectory() else { throw LocalAlignmentError.unavailable }
            model = try OmniASRCTC(modelDirectory: directory, threads: 1)
        }
        try Task.checkCancellation()
        guard let model else { throw LocalAlignmentError.unavailable }
        return try await model.align(request)
    }
}

// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// UVR MDX-Net ONNX 모델 래퍼 (ONNX Runtime + 선택적 CoreML 실행 공급자).
// 전처리·후처리는 python-audio-separator (MIT) 의 MDXSeparator.run_model 과 같은 순서를 따른다:
//   STFT → [L실수, L허수, R실수, R허수] × dim_f × dim_t 텐서 → 저주파 3빈 0 → 모델 → iSTFT(빈 부족분 0)
// 모델 출력(primary stem)이 곧 반주다. 보컬 = 원곡 − 반주 × compensate.

import Foundation
import OnnxRuntimeBindings

/// 모델별 고정 설정 (UVR model_data_new.json 의 해시 키로 확인한 값)
struct MDXModelConfig: Sendable {
    let fileName: String
    let nFFT: Int
    let hop: Int
    let dimF: Int
    let dimT: Int
    let compensate: Float
    let sampleRate: Double

    /// 한 창의 길이 = hop × (dim_t − 1)
    var chunkSize: Int { hop * (dimT - 1) }
    /// 창 가장자리에서 버리는 길이 = n_fft / 2
    var edgeTrim: Int { nFFT / 2 }

    /// UVR-MDX-NET Karaoke 2 — 리드 보컬만 빼고 코러스는 반주에 남긴다.
    /// UVR 해시 1d64a6d2c30f709b8c9b4ce1366d96ee (scripts/fetch-models.sh 가 검증)
    static let karaoke2 = MDXModelConfig(
        fileName: "UVR_MDXNET_KARA_2",
        nFFT: 5120,
        hop: 1024,
        dimF: 2048,
        dimT: 256,
        compensate: 1.065,
        sampleRate: 44_100
    )
}

/// 추론 백엔드
enum InferenceBackend: String, CaseIterable, Identifiable, Sendable {
    /// CoreML (CPU·GPU·뉴럴엔진 중 CoreML 이 선택)
    case coreMLAll
    /// CoreML, 뉴럴엔진 제외
    case coreMLGPU
    /// ONNX Runtime CPU
    case cpu

    var id: String { rawValue }

    var label: String {
        switch self {
        case .coreMLAll: "CoreML (자동)"
        case .coreMLGPU: "CoreML (GPU)"
        case .cpu: "CPU"
        }
    }
}

enum MDXSeparatorError: LocalizedError {
    case modelNotFound(String)
    case onnx(String, underlying: Error?)

    var errorDescription: String? {
        switch self {
        case let .modelNotFound(name):
            "모델 파일 \(name).onnx 이 앱에 없습니다. 터미널에서 scripts/fetch-models.sh 실행 후 다시 빌드하세요."
        case let .onnx(message, underlying):
            underlying.map { "\(message): \($0.localizedDescription)" } ?? message
        }
    }
}

/// 한 번에 한 스레드에서만 쓴다 (워커 스레드). 로드는 백그라운드에서 하고 워커로 넘긴다.
final class MDXSeparator: ChunkSeparating, @unchecked Sendable {
    let config: MDXModelConfig
    let backend: InferenceBackend

    var chunkSize: Int { config.chunkSize }
    var edgeTrim: Int { config.edgeTrim }

    private let env: ORTEnv
    private let session: ORTSession
    private let stft: STFT
    private let inputShape: [NSNumber]

    // [4, dimF, dimT] float32 입력 텐서 버퍼 (재사용)
    private let inputData: NSMutableData

    /// 마지막 separate 호출 중 모델 실행(session.run)만의 시간 — 전후처리(STFT)와 나눠 보기 위함
    private(set) var lastModelMilliseconds: Double = 0

    init(config: MDXModelConfig, backend: InferenceBackend, modelURL: URL, cacheDirectory: URL?) throws {
        self.config = config
        self.backend = backend
        stft = try STFT(nFFT: config.nFFT, hop: config.hop)
        inputShape = [1, 4, NSNumber(value: config.dimF), NSNumber(value: config.dimT)]
        inputData = NSMutableData(length: 4 * config.dimF * config.dimT * MemoryLayout<Float>.size)!

        do {
            env = try OnnxRuntimeEnvironment.env()
            let options = try ORTSessionOptions()
            try options.setGraphOptimizationLevel(.all)
            try Self.appendExecutionProvider(backend, to: options, cacheDirectory: cacheDirectory)
            session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)
        } catch {
            throw MDXSeparatorError.onnx("ONNX 세션 생성 실패 (\(backend.label))", underlying: error)
        }
    }

    private static func appendExecutionProvider(_ backend: InferenceBackend, to options: ORTSessionOptions, cacheDirectory: URL?) throws {
        let computeUnits: String
        switch backend {
        case .cpu: return
        case .coreMLAll: computeUnits = "ALL" // 헤더 주석은 "All" 이지만 실제 허용값은 대문자 (coreml_options.cc)
        case .coreMLGPU: computeUnits = "CPUAndGPU"
        }
        var providerOptions: [String: String] = [
            "MLComputeUnits": computeUnits,
            "ModelFormat": "MLProgram",
            // UVR 모델은 배치 차원이 기호('batch_size')라 "1"(정적 형태만)이면 CoreML 이 모든 노드를 거부하고
            // 전부 CPU 로 떨어진다 (ORT verbose 로그로 확인). ObjC API 에 배치 고정(free dimension override)이 없어 "0".
            "RequireStaticInputShapes": "0",
        ]
        if let cacheDirectory {
            // 컴파일된 CoreML 모델 캐시 (두 번째 실행부터 로드가 빨라진다)
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            providerOptions["ModelCacheDirectory"] = cacheDirectory.path
        }
        do {
            try options.appendCoreMLExecutionProvider(withOptionsV2: providerOptions)
        } catch where providerOptions["ModelCacheDirectory"] != nil {
            // 이 버전이 캐시 옵션을 모르면 캐시 없이 재시도
            providerOptions.removeValue(forKey: "ModelCacheDirectory")
            try options.appendCoreMLExecutionProvider(withOptionsV2: providerOptions)
        }
    }

    /// 번들 안 Models/ 에서 모델 URL 을 찾는다.
    static func bundledModelURL(for config: MDXModelConfig) throws -> URL {
        guard let url = Bundle.main.url(forResource: config.fileName, withExtension: "onnx", subdirectory: "Models") else {
            throw MDXSeparatorError.modelNotFound(config.fileName)
        }
        return url
    }

    // MARK: - ChunkSeparating

    func separate(
        left: UnsafeBufferPointer<Float>,
        right: UnsafeBufferPointer<Float>,
        outLeft: UnsafeMutableBufferPointer<Float>,
        outRight: UnsafeMutableBufferPointer<Float>
    ) throws {
        let dimF = config.dimF
        let dimT = config.dimT
        let plane = dimF * dimT
        precondition(left.count == chunkSize && right.count == chunkSize)
        precondition(stft.frameCount(forSampleCount: chunkSize) == dimT)

        // 1) STFT → 입력 텐서 [L re, L im, R re, R im]
        let tensor = inputData.mutableBytes.assumingMemoryBound(to: Float.self)
        stft.forward(left, maxBins: dimF, real: tensor, imag: tensor + plane)
        stft.forward(right, maxBins: dimF, real: tensor + 2 * plane, imag: tensor + 3 * plane)

        // 2) 저주파 3빈 제거 (UVR: spek[:, :, :3, :] *= 0)
        for channel in 0..<4 {
            (tensor + channel * plane).update(repeating: 0, count: 3 * dimT)
        }

        // 3) 추론
        // ⚠️ tensorData() 는 복사하지 않고 ORTValue 가 가진 메모리를 가리킨다 (freeWhenDone:NO).
        // ORTValue 가 해제되면 그 메모리도 풀로 돌아가므로, 다 읽을 때까지 outputValue 를 살려 둔다.
        let outputValue: ORTValue
        let output: NSMutableData
        do {
            let input = try ORTValue(tensorData: inputData, elementType: .float, shape: inputShape)
            let runStart = ContinuousClock.now
            let results = try session.run(withInputs: ["input": input], outputNames: ["output"], runOptions: nil)
            lastModelMilliseconds = (ContinuousClock.now - runStart).milliseconds
            guard let value = results["output"] else { throw MDXSeparatorError.onnx("모델 출력 'output' 없음", underlying: nil) }
            outputValue = value
            output = try value.tensorData()
        } catch let error as MDXSeparatorError {
            throw error
        } catch {
            throw MDXSeparatorError.onnx("추론 실패", underlying: error)
        }
        guard output.length >= 4 * plane * MemoryLayout<Float>.size else {
            throw MDXSeparatorError.onnx("모델 출력 크기가 예상과 다릅니다 (\(output.length) bytes)", underlying: nil)
        }

        // 4) iSTFT (dim_f 위 빈은 0) → 반주
        withExtendedLifetime(outputValue) {
            let predicted = output.bytes.assumingMemoryBound(to: Float.self)
            stft.inverse(real: predicted, imag: predicted + plane, providedBins: dimF, frames: dimT, output: outLeft)
            stft.inverse(real: predicted + 2 * plane, imag: predicted + 3 * plane, providedBins: dimF, frames: dimT, output: outRight)
        }
    }
}

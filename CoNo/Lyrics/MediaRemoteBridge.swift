// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// macOS "지금 재생 중" (MediaRemote) 연동. macOS 15.4+ 는 서드파티 앱의 MediaRemote 접근을 막았으므로
// 번들에 넣은 mediaremote-adapter(BSD-3)를 애플 서명 `/usr/bin/perl` 로 실행해 읽고 제어한다.
// (ThirdParty/mediaremote-adapter/VENDORED.md) — 애플이 이 길을 막으면 nil/false 를 돌려주고, 호출 쪽이 대안으로 넘어간다.
//
// 음악 앱이 아닌 앱(브라우저의 YouTube Music 등)에 토글이 아닌 명확한 "멈춤/재생" 을 보내는 데 쓴다.

import Foundation

/// 어댑터 `get --micros` 결과 (필요한 키만)
struct RemoteNowPlaying: Decodable, Sendable {
    let bundleIdentifier: String
    let parentApplicationBundleIdentifier: String?
    let playing: Bool
    let title: String
    let artist: String?
    let album: String?
    let durationMicros: Double?
    let elapsedTimeMicros: Double?
    let timestampEpochMicros: Double?
    let playbackRate: Double?

    /// 이 재생 정보가 캡처 중인 앱의 것인지 (웹앱·헬퍼는 부모 번들 ID 나 하위 ID 로 온다)
    func belongs(to bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleIdentifier == bundleID
            || parentApplicationBundleIdentifier == bundleID
            || bundleIdentifier.hasPrefix(bundleID + ".")
    }
}

final class MediaRemoteBridge: Sendable {
    /// 번들에 어댑터가 없으면 nil
    static let shared = MediaRemoteBridge()

    private let scriptPath: String
    private let frameworkPath: String

    private init?() {
        guard let script = Bundle.main.path(forResource: "mediaremote-adapter", ofType: "pl"),
              let frameworks = Bundle.main.privateFrameworksPath
        else { return nil }
        let framework = (frameworks as NSString).appendingPathComponent("MediaRemoteAdapter.framework")
        guard FileManager.default.fileExists(atPath: framework) else { return nil }
        scriptPath = script
        frameworkPath = framework
    }

    /// 지금 재생 중인 미디어 (없거나 실패하면 nil)
    func current() async -> RemoteNowPlaying? {
        guard let output = await run(["get", "--micros", "--no-artwork"]), output.status == 0 else { return nil }
        return try? JSONDecoder().decode(RemoteNowPlaying?.self, from: output.data) ?? nil
    }

    /// 지금 재생 중인 앱에 명령. 성공하면 true.
    func send(_ command: PlayerCommand) async -> Bool {
        // 어댑터 명령 번호: kMRPlay = 0, kMRPause = 1
        let code = switch command {
        case .play: "0"
        case .pause: "1"
        }
        return await run(["send", code])?.status == 0
    }

    /// `/usr/bin/perl 스크립트 프레임워크 인자…` 프로세스 (실행은 호출 쪽이)
    func makeProcess(_ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptPath, frameworkPath] + arguments
        return process
    }

    /// 지금 재생 중인 앱에서 곡 안 위치로 이동 (초). 성공하면 true.
    func seek(toSeconds seconds: Double) async -> Bool {
        // 어댑터 단위는 마이크로초 정수
        await run(["seek", String(Int((max(0, seconds) * 1_000_000).rounded()))])?.status == 0
    }

    /// perl 로 어댑터를 실행한다. 3초 안에 안 끝나면 끊는다 (MediaRemote 가 응답하지 않는 경우).
    private func run(_ arguments: [String]) async -> (status: Int32, data: Data)? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let process = makeProcess(arguments)
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: watchdog)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()
                continuation.resume(returning: (process.terminationStatus, data))
            }
        }
    }
}

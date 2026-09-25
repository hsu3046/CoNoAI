// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// Apple Music 앱의 현재 곡·재생 위치를 공식 스크립팅(AppleScript)으로 읽는다.
// (macOS 15.4+ 는 서드파티의 MediaRemote "지금 재생 중" 조회를 막았다 — docs/DECISIONS.md)
//
// - 첫 호출 때 "자동화" 권한 창이 뜨고, 응답할 때까지 호출이 블록된다 → 전용 직렬 큐에서만 실행.
// - 음악 앱이 꺼져 있으면 켜지 않는다 (`application "Music" is running` 로 먼저 확인).

import Foundation

struct TrackInfo: Hashable, Sendable {
    /// 음악 앱의 persistent ID (곡 변경 감지·가사 캐시 키)
    let id: String
    let title: String
    let artist: String
    let album: String
    /// 초
    let duration: Double
}

enum PlayerState: String, Sendable {
    case playing, paused, stopped, notRunning
}

struct NowPlayingSample: Sendable {
    let state: PlayerState
    let track: TrackInfo?
    /// 곡 안 위치 (초)
    let position: Double
    /// 조회 시각 (mach_absolute_time, 호출 전후의 중간)
    let hostTime: UInt64
}

enum NowPlayingError: LocalizedError {
    case automationDenied
    case script(String)

    var errorDescription: String? {
        switch self {
        case .automationDenied:
            "음악 앱 정보를 읽을 권한이 없습니다. 시스템 설정 › 개인정보 보호 및 보안 › 자동화 › CoNo 에서 '음악'을 허용해 주세요."
        case let .script(message):
            "음악 앱 정보를 읽지 못했습니다: \(message)"
        }
    }
}

final class AppleMusicNowPlaying: @unchecked Sendable {
    static let bundleID = "com.apple.Music"

    private let queue = DispatchQueue(label: "space.knowai.cono.nowplaying", qos: .userInitiated)
    /// NSAppleScript 는 스레드 안전하지 않으므로 이 큐에서만 만들고 쓴다
    private var script: NSAppleScript?

    private static let source = """
    if application "Music" is running then
        tell application "Music"
            set st to player state as string
            if st is "stopped" then return {st}
            set t to current track
            return {st, player position, persistent ID of t, name of t, artist of t, album of t, duration of t}
        end tell
    else
        return {"notRunning"}
    end if
    """

    func poll() async -> Result<NowPlayingSample, NowPlayingError> {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: pollSync())
            }
        }
    }

    private func pollSync() -> Result<NowPlayingSample, NowPlayingError> {
        if script == nil {
            script = NSAppleScript(source: Self.source)
        }
        guard let script else { return .failure(.script("스크립트 생성 실패")) }

        var errorInfo: NSDictionary?
        let before = mach_absolute_time()
        let result = script.executeAndReturnError(&errorInfo)
        let after = mach_absolute_time()
        let hostTime = before + (after - before) / 2

        if let errorInfo {
            let code = errorInfo[NSAppleScript.errorNumber] as? Int
            // -1743 = errAEEventNotPermitted (자동화 권한 거부), -1744 = 사용자 동의 필요
            if code == -1743 || code == -1744 {
                return .failure(.automationDenied)
            }
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "알 수 없는 오류"
            return .failure(.script("\(message) (\(code ?? 0))"))
        }

        let stateText = result.atIndex(1)?.stringValue ?? "stopped"
        let state = PlayerState(rawValue: stateText) ?? .stopped
        guard state == .playing || state == .paused, result.numberOfItems >= 7 else {
            return .success(NowPlayingSample(state: state, track: nil, position: 0, hostTime: hostTime))
        }

        let position = result.atIndex(2)?.doubleValue ?? 0
        let track = TrackInfo(
            id: result.atIndex(3)?.stringValue ?? "",
            title: result.atIndex(4)?.stringValue ?? "",
            artist: result.atIndex(5)?.stringValue ?? "",
            album: result.atIndex(6)?.stringValue ?? "",
            duration: result.atIndex(7)?.doubleValue ?? 0
        )
        return .success(NowPlayingSample(state: state, track: track, position: position, hostTime: hostTime))
    }
}

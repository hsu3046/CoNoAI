// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// 음악 앱 조회 AppleScript 원문. 앱 실행 시점에야 컴파일되므로 단위 테스트(LyricsTests)가 미리 컴파일해 본다.
// ⚠️ AppleScript 예약어를 변수 이름으로 쓰지 말 것 — `st`(1st 의 서수 접미사)를 써서 -2741 로 실패한 적이 있다.

enum AppleMusicScript {
    /// 반환: {"notRunning"} | {"stopped"} | {상태, 재생 위치, persistent ID, 제목, 아티스트, 앨범, 길이}
    static let source = """
    if application "Music" is running then
        tell application "Music"
            set playerStateText to player state as string
            if playerStateText is "stopped" then return {playerStateText}
            set playingTrack to current track
            return {playerStateText, player position, persistent ID of playingTrack, name of playingTrack, artist of playingTrack, album of playingTrack, duration of playingTrack}
        end tell
    else
        return {"notRunning"}
    end if
    """

    /// 재생 제어. 음악 앱이 꺼져 있으면 켜지 않는다 (`play` 는 앱을 띄우므로 먼저 확인).
    static func command(_ verb: PlayerCommand) -> String {
        """
        if application "Music" is running then
            tell application "Music" to \(verb.rawValue)
        end if
        """
    }
}

extension AppleMusicScript {
    /// 지금 곡의 앨범 아트 원본 바이트 (없으면 missing value). 음악 앱이 꺼져 있으면 켜지 않는다.
    static let artwork = """
    if application "Music" is running then
        tell application "Music"
            try
                set playingTrack to current track
                if (count of artworks of playingTrack) > 0 then return raw data of artwork 1 of playingTrack
            end try
        end tell
    end if
    return missing value
    """
}

extension AppleMusicScript {
    /// 곡 안 위치로 이동 (초). AppleScript 숫자는 로케일과 무관하게 소수점이 "." 이다.
    static func seek(to seconds: Double) -> String {
        """
        if application "Music" is running then
            tell application "Music" to set player position to \(String(format: "%.3f", max(0, seconds)))
        end if
        """
    }
}

enum PlayerCommand: String, CaseIterable, Sendable {
    case play
    case pause
}

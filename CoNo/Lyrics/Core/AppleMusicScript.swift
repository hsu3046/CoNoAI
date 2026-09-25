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
}

// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import Foundation
import Testing

struct LyricsTapSyncTests {
    private func snapshot(_ position: Double, capture: Double? = nil, track: String = "song", playing: Bool = true,
                          discontinuities: Int = 0) -> LyricsTimingSnapshot {
        LyricsTimingSnapshot(trackID: track, position: position, captureTime: capture ?? position,
                             isPlaying: playing, discontinuities: discontinuities)
    }

    @Test func recordsHeardTimesAndExportsRoundTrippableKoreanLyrics() throws {
        var session = try LyricsTapSync(trackID: "song", plainLyrics: " 첫 줄 \r\n\r\n둘째 줄 👩🏽‍🎤")
        #expect(session.lines == ["첫 줄", "둘째 줄 👩🏽‍🎤"])
        try session.arm(at: snapshot(2))
        try session.record(at: snapshot(2.1234))
        try session.record(at: snapshot(64.9996))
        #expect(session.isComplete)
        #expect(!session.isArmed)
        let lrc = try session.lrc()
        #expect(lrc == "[00:02.123] 첫 줄\n[01:05.000] 둘째 줄 👩🏽‍🎤\n")
        #expect(LRCParser.parse(lrc) == session.preview)
        #expect(session.previewText(at: 5) == "첫 줄")
        #expect(session.previewText(at: 20) == nil)
        #expect(session.previewText(at: 65) == "둘째 줄 👩🏽‍🎤")
        #expect(session.previewText(at: 1) == nil, "미리보기 되감기는 이전 활성 줄을 붙잡지 않는다")
    }

    @Test func pauseWrongTrackAndStaleSnapshotCannotRecord() throws {
        for blocked in [nil, snapshot(2, playing: false), snapshot(2, track: "next")] {
            var session = try LyricsTapSync(trackID: "song", plainLyrics: "첫 줄\n둘째 줄")
            try session.arm(at: snapshot(1))
            session.observe(blocked)
            #expect(!session.isArmed)
            #expect(session.interruption != nil)
            #expect(throws: LyricsTapSyncError.self) { try session.record(at: snapshot(2)) }
            #expect(session.timestamps.isEmpty)
        }
    }

    @Test func seeksRequireRearmingAndNeverWriteNonIncreasingTimes() throws {
        var session = try LyricsTapSync(trackID: "song", plainLyrics: "첫 줄\n둘째 줄\n셋째 줄")
        try session.arm(at: snapshot(10))
        try session.record(at: snapshot(10))
        session.observe(snapshot(9, capture: 10.1))
        #expect(!session.isArmed, "플레이어 폴링 세대가 바뀌기 전의 작은 되감기도 거른다")
        try session.arm(at: snapshot(9, capture: 10.1))
        #expect(throws: LyricsTapSyncError.self) { try session.record(at: snapshot(9, capture: 10.1)) }
        #expect(session.timestamps == [10])
        session.observe(snapshot(11, capture: 12.1, discontinuities: 1))
        #expect(!session.isArmed)
        try session.arm(at: snapshot(12, capture: 13.1, discontinuities: 1))
        try session.record(at: snapshot(12, capture: 13.1, discontinuities: 1))
        #expect(session.timestamps == [10, 12])
    }

    @Test func undoAndResetLeaveTextButRequireExplicitRecording() throws {
        var session = try LyricsTapSync(trackID: "song", plainLyrics: "첫 줄\n둘째 줄")
        try session.arm(at: snapshot(1))
        try session.record(at: snapshot(1))
        #expect(throws: LyricsTapSyncError.self) { try session.lrc() }
        session.undo()
        #expect(session.timestamps.isEmpty)
        #expect(!session.isArmed)
        try session.arm(at: snapshot(3))
        try session.record(at: snapshot(3))
        session.reset()
        #expect(session.plainLyrics == "첫 줄\n둘째 줄")
        #expect(session.timestamps.isEmpty)
    }

    @Test(arguments: ["", " \n\r", "[00:01]이미 시간 태그", "안녕<00:01>세계", "< 00:05 >가사", "<00:5e0>가사",
                      "[ 00:05 ]가사", String(repeating: "가", count: 501)])
    func rejectsInvalidOrAmbiguousPlainText(_ text: String) {
        #expect(throws: LyricsTapSyncError.self) { try LyricsTapSync(trackID: "song", plainLyrics: text) }
    }

    @Test func invalidNumericPositionsCannotEnterAnLRC() throws {
        for position in [Double.nan, .infinity, -1, 86_400] {
            var session = try LyricsTapSync(trackID: "song", plainLyrics: "가사")
            #expect(throws: LyricsTapSyncError.self) { try session.arm(at: snapshot(position)) }
        }
    }

    @Test func bracketedTextCannotBecomeGlobalLRCMetadata() throws {
        var session = try LyricsTapSync(trackID: "song", plainLyrics: "[후렴] 가사\n[offset:1000] 그대로")
        try session.arm(at: snapshot(1))
        try session.record(at: snapshot(1))
        try session.record(at: snapshot(3))
        #expect(LRCParser.parse(try session.lrc()) == session.preview)
    }

    @Test(arguments: ["\u{2028}", "\u{2029}", "\u{0085}", "\u{000B}", "\u{000C}"])
    func unicodeLineSeparatorsRoundTripLikeLRCNewlines(_ separator: String) throws {
        var session = try LyricsTapSync(trackID: "song", plainLyrics: "첫 줄\(separator)둘째 줄")
        #expect(session.lines.count == 2)
        try session.arm(at: snapshot(1))
        try session.record(at: snapshot(1))
        try session.record(at: snapshot(3))
        #expect(LRCParser.parse(try session.lrc()) == session.preview)
    }
}

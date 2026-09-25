// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// "지금 귀에 들리는 소리가 곡의 몇 초인가" 계산.
//
// 플레이어(Apple Music)가 알려주는 재생 위치는 "지금 캡처되는 소리" 의 위치다.
// 그 순간의 캡처 스트림 시각과 짝지은 앵커를 쌓아 두고,
// 들리는 소리의 캡처 시각(= 몇 초 전) 에 해당하는 앵커로 곡 위치를 계산한다.
// → 들리는 소리보다 뒤에 일어난 일시정지·되감기·곡 변경이 지금 표시를 흔들지 않는다.

import Foundation

struct PlaybackAnchor: Equatable, Sendable {
    /// 캡처 스트림 시각 (초, DelayPipeline 캡처 쪽 시간축)
    let captureTime: Double
    /// 그때 플레이어가 알려준 곡 위치 (초)
    let songPosition: Double
    let isPlaying: Bool
    /// 곡 식별자 (플레이어의 persistent ID). nil = 재생 중인 곡 없음
    let trackID: String?
}

struct SongPosition: Equatable, Sendable {
    let trackID: String
    let seconds: Double
    let isPlaying: Bool
}

struct SongClock: Sendable {
    /// 보관할 앵커 범위 (초). 들리는 소리는 지연(수 초)만큼 과거이므로 그보다 넉넉히.
    var retentionSeconds: Double = 120
    private(set) var anchors: [PlaybackAnchor] = []

    mutating func add(_ anchor: PlaybackAnchor) {
        // 캡처 시각 오름차순 유지 (역행 앵커는 버림)
        if let last = anchors.last, anchor.captureTime < last.captureTime { return }
        anchors.append(anchor)
        let cutoff = anchor.captureTime - retentionSeconds
        if let firstKept = anchors.firstIndex(where: { $0.captureTime >= cutoff }), firstKept > 0 {
            anchors.removeFirst(firstKept)
        }
    }

    mutating func reset() {
        anchors.removeAll()
    }

    /// 캡처 시각 c 의 소리가 곡 어디였는지. c 이전의 가장 최근 앵커 기준.
    func position(atCaptureTime c: Double) -> SongPosition? {
        guard let anchor = anchors.last(where: { $0.captureTime <= c }), let trackID = anchor.trackID else { return nil }
        let seconds = anchor.isPlaying ? anchor.songPosition + (c - anchor.captureTime) : anchor.songPosition
        return SongPosition(trackID: trackID, seconds: seconds, isPlaying: anchor.isPlaying)
    }
}

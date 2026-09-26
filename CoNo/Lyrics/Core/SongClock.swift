// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
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

    /// 매끄럽게 할 때 합치는 최근 앵커 수 (0.5초 폴링이면 약 4초)
    var smoothingCount = 8

    /// 앵커 index 에서 쓸 (곡 위치 − 캡처 시각). 끊김 없이 이어진 최근 앵커들의 중앙값.
    /// 플레이어 위치 보고의 수십 ms 흔들림 때문에 가장 최근 앵커 하나만 쓰면 곡 위치가 앞뒤로 튄다.
    private func smoothedResidual(at index: Int, tolerance: Double = 0.3) -> Double {
        var residuals = [anchors[index].songPosition - anchors[index].captureTime]
        var i = index
        while i > 0, residuals.count < smoothingCount {
            let previous = anchors[i - 1]
            let current = anchors[i]
            let drift = (current.songPosition - previous.songPosition) - (current.captureTime - previous.captureTime)
            guard previous.isPlaying, previous.trackID == current.trackID, abs(drift) < tolerance else { break }
            residuals.append(previous.songPosition - previous.captureTime)
            i -= 1
        }
        residuals.sort()
        let middle = residuals.count / 2
        return residuals.count % 2 == 1 ? residuals[middle] : (residuals[middle - 1] + residuals[middle]) / 2
    }

    /// 역변환: 곡 위치 s 가 캡처된(될) 시각. 들리는 시점 heardAt 의 앵커 구간을 기준으로 외삽한다
    /// (그 뒤로 계속 재생된다고 가정 — 현재 줄·다음 줄의 음절 타이밍 계산용). 일시정지 앵커면 nil.
    func captureTime(forSongPosition s: Double, heardAt c: Double) -> Double? {
        guard let index = anchors.lastIndex(where: { $0.captureTime <= c }), anchors[index].isPlaying else { return nil }
        return s - smoothedResidual(at: index)
    }

    /// heardAt 의 앵커부터 거슬러 올라가며 끊김 없이 이어진 재생 구간의 시작 캡처 시각.
    /// (같은 곡·재생 중·앵커 간 곡 진행 ≈ 캡처 진행) — 되감기 이전 데이터를 섞지 않기 위해.
    func continuousSegmentStart(heardAt c: Double, tolerance: Double = 0.3) -> Double? {
        guard var index = anchors.lastIndex(where: { $0.captureTime <= c }), anchors[index].isPlaying else { return nil }
        while index > 0 {
            let previous = anchors[index - 1]
            let current = anchors[index]
            let drift = (current.songPosition - previous.songPosition) - (current.captureTime - previous.captureTime)
            guard previous.isPlaying, previous.trackID == current.trackID, abs(drift) < tolerance else { break }
            index -= 1
        }
        return anchors[index].captureTime
    }

    /// 이동(seek) 뒤 곡이 실제로 target 위치에 닿은 캡처 시각. start(명령을 보낸 캡처 시각) 이후의 재생 앵커 중
    /// 처음으로 target 근처(−0.5…+tolerance 초)를 보고한 앵커에서 거슬러 계산한다. 아직 안 닿았으면 nil.
    /// (명령이 끝난 순간 ≠ 새 위치 소리의 시작 — 브라우저는 버퍼링으로 더 늦게 옮겨 간다)
    func captureTime(whenReaching target: Double, after start: Double, tolerance: Double = 3) -> Double? {
        for anchor in anchors where anchor.captureTime >= start && anchor.isPlaying {
            let ahead = anchor.songPosition - target
            if ahead >= -0.5, ahead <= tolerance {
                return max(start, anchor.captureTime - max(0, ahead))
            }
        }
        return nil
    }

    /// 이동 도착을 앵커에 반영한다: 도착 시각에 새 위치 앵커를 끼우고, 그 뒤의 옛 위치 앵커(플레이어 보고가 늦어
    /// 옛 위치를 계속 외삽한 것)를 지운다. 안 하면 도착~첫 새 앵커 사이의 소리가 옛 위치로 계산돼
    /// 진행 막대·가사가 잠깐 옛 위치로 튄다. 도착을 찾았으면 그 캡처 시각을 돌려준다.
    mutating func settleSeek(toward target: Double, after start: Double, tolerance: Double = 3) -> Double? {
        guard let arrival = captureTime(whenReaching: target, after: start, tolerance: tolerance),
              let first = anchors.firstIndex(where: { anchor in
                  anchor.captureTime >= start && anchor.isPlaying
                      && anchor.songPosition - target >= -0.5 && anchor.songPosition - target <= tolerance
              })
        else { return nil }
        let reported = anchors[first]
        let settled = PlaybackAnchor(
            captureTime: arrival,
            songPosition: reported.songPosition - (reported.captureTime - arrival),
            isPlaying: true,
            trackID: reported.trackID
        )
        anchors.removeAll { $0.captureTime >= arrival && $0.captureTime < reported.captureTime }
        let insertAt = anchors.firstIndex { $0.captureTime > arrival } ?? anchors.count
        anchors.insert(settled, at: insertAt)
        return arrival
    }

    /// 캡처 시각 c 의 소리가 곡 어디였는지. c 이전의 가장 최근 앵커가 속한 연속 구간의 중앙값 기준.
    func position(atCaptureTime c: Double) -> SongPosition? {
        guard let index = anchors.lastIndex(where: { $0.captureTime <= c }), let trackID = anchors[index].trackID else { return nil }
        let anchor = anchors[index]
        let seconds = anchor.isPlaying ? c + smoothedResidual(at: index) : anchor.songPosition
        return SongPosition(trackID: trackID, seconds: seconds, isPlaying: anchor.isPlaying)
    }
}

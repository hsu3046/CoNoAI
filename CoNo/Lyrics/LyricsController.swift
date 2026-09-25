// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// 가사 기능 조립: 플레이어 폴링 → 곡 위치 앵커(SongClock) → 곡별 가사 로드 → 화면 표시값 계산.
// 지금은 Apple Music 만 곡 정보·재생 위치를 준다 (L1). 다른 앱은 소리 기반 자동 싱크(L2) 예정.

import Foundation
import Observation

/// 음절 단위 색칠에 쓰는 분리된 보컬 음정 (AI 분리 모드에서만)
struct VocalTimingSource {
    let timeline: PitchTimeline
    /// 출력 스트림 = 캡처 스트림 + streamOffset (AI 분리의 rightContext)
    let streamOffset: Double
}

/// 화면에 그릴 가사 상태
struct LyricsDisplay: Equatable {
    var current: String?
    /// 현재 줄 진행률 0~1 (보컬 데이터가 없을 때의 줄 길이 비례 색칠)
    var progress: Double = 0
    /// 음절 정렬로 계산한 칠해진 글자 수 (소수 = 현재 글자 일부). nil 이면 progress 사용
    var highlightedCharacters: Double?
    var next: String?
    /// 다음 줄까지 남은 초 (간주 중 곧 시작할 때만)
    var countdown: Double?
}

@MainActor
@Observable
final class LyricsController {
    enum Status: Equatable {
        case inactive
        /// 곡 정보·재생 위치를 줄 수 없는 앱
        case unsupportedSource
        case waitingForPlayer
        case loading(TrackInfo)
        case ready(TrackInfo, synced: Bool)
        case notFound(TrackInfo)
        case failed(String)
    }

    private(set) var status: Status = .inactive
    /// 사용자가 맞추는 가사 싱크 (초). + 면 가사를 앞당긴다.
    var offsetSeconds: Double = 0

    private let nowPlaying = AppleMusicNowPlaying()
    private let client = LRCLIBClient()
    private var clock = SongClock()
    private var lyricsByTrack: [String: TimedLyrics?] = [:]
    private var tracks: [String: TrackInfo] = [:]
    private var loadingTrackIDs: Set<String> = []
    /// 곡별 마지막 상태 (일시 오류에서 회복하거나 곡을 오갈 때 되돌리기 위해)
    private var statusByTrack: [String: Status] = [:]
    private var currentTrackID: String?
    private var pollTask: Task<Void, Never>?

    /// 음절 정렬용 보컬 데이터 (엔진이 AI 분리 모드로 시작할 때 넣는다)
    var vocalSource: VocalTimingSource?
    /// 줄별 음절 정렬 캐시 (키: 곡ID#줄번호). 분석이 더 진행되면 다시 계산한다.
    private struct WipeCacheEntry {
        let wipe: LineWipe?
        let knownUntil: Double
        let complete: Bool
    }
    @ObservationIgnored private var wipeCache: [String: WipeCacheEntry] = [:]

    /// 가사를 지원하는 소스인지 (지금은 Apple Music 만)
    static func supports(bundleID: String?) -> Bool {
        bundleID == AppleMusicNowPlaying.bundleID
    }

    /// - Parameter captureTime: 호스트 시각 → 캡처 스트림 시각 (DelayPipeline 캡처 시계)
    func start(sourceBundleID: String?, captureTime: @escaping @MainActor (UInt64) -> Double?) {
        stop()
        guard Self.supports(bundleID: sourceBundleID) else {
            status = .unsupportedSource
            return
        }
        status = .waitingForPlayer
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce(captureTime: captureTime)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        clock.reset()
        wipeCache.removeAll()
        vocalSource = nil
        currentTrackID = nil
        status = .inactive
    }

    private func pollOnce(captureTime: @MainActor (UInt64) -> Double?) async {
        let result = await nowPlaying.poll()
        guard !Task.isCancelled else { return }
        switch result {
        case let .failure(error):
            status = .failed(error.localizedDescription)
        case let .success(sample):
            guard let capture = captureTime(sample.hostTime) else { return }
            clock.add(PlaybackAnchor(
                captureTime: capture,
                songPosition: sample.position,
                isPlaying: sample.state == .playing,
                trackID: sample.track?.id
            ))
            guard let track = sample.track else {
                currentTrackID = nil
                status = .waitingForPlayer
                return
            }
            tracks[track.id] = track
            currentTrackID = track.id
            if lyricsByTrack[track.id] == nil, !loadingTrackIDs.contains(track.id) {
                load(track)
            } else if let known = statusByTrack[track.id] {
                status = known
            }
        }
    }

    private func load(_ track: TrackInfo) {
        loadingTrackIDs.insert(track.id)
        status = .loading(track)
        Task { [weak self] in
            guard let self else { return }
            let outcome: Status
            do {
                switch try await client.lyrics(for: track) {
                case let .found(candidate):
                    if let synced = candidate.syncedLyrics {
                        lyricsByTrack[track.id] = .some(LRCParser.parse(synced))
                        outcome = .ready(track, synced: true)
                    } else {
                        lyricsByTrack[track.id] = .some(nil)
                        outcome = .ready(track, synced: false)
                    }
                case .notFound:
                    lyricsByTrack[track.id] = .some(nil)
                    outcome = .notFound(track)
                }
                statusByTrack[track.id] = outcome
            } catch {
                // 실패는 기억하지 않는다 → 다음 폴링 때 다시 시도
                outcome = .failed(error.localizedDescription)
            }
            loadingTrackIDs.remove(track.id)
            if currentTrackID == track.id { status = outcome }
        }
    }

    /// 캡처 시각 c 의 소리(= 지금 귀에 들리는 소리)에 맞는 가사 표시값.
    func display(atCaptureTime c: Double) -> (track: TrackInfo?, lyrics: LyricsDisplay?) {
        guard let position = clock.position(atCaptureTime: c) else { return (nil, nil) }
        let track = tracks[position.trackID]
        guard let entry = lyricsByTrack[position.trackID], let lyrics = entry else { return (track, nil) }

        let t = position.seconds + offsetSeconds
        var display = LyricsDisplay()
        if let index = lyrics.lineIndex(at: t) {
            let line = lyrics.lines[index]
            let end = lyrics.end(of: index)
            display.current = line.text
            display.progress = end > line.start ? min(max((t - line.start) / (end - line.start), 0), 1) : 1
            display.next = lyrics.nextLineIndex(after: line.start).map { lyrics.lines[$0].text }
            if let wipe = lineWipe(trackID: position.trackID, lineIndex: index, text: line.text,
                                   songStart: line.start - offsetSeconds, songEnd: end - offsetSeconds, heardAt: c) {
                // 음절 타이밍은 소리에서 잰 실제 곡 시각이라 사용자 오프셋 없이 비교한다
                display.highlightedCharacters = wipe.highlightedCharacters(at: position.seconds)
            }
        } else if let nextIndex = lyrics.nextLineIndex(after: t) {
            let next = lyrics.lines[nextIndex]
            display.next = next.text
            let remaining = next.start - t
            if remaining <= 5 { display.countdown = remaining }
        }
        return (track, display)
    }

    /// 현재 줄의 음절 타이밍. 곡 구간 → 캡처 시각 → 출력 스트림 시각으로 바꿔 보컬 프레임을 가져와 정렬한다.
    private func lineWipe(trackID: String, lineIndex: Int, text: String, songStart: Double, songEnd: Double, heardAt c: Double) -> LineWipe? {
        guard let source = vocalSource,
              let captureStart = clock.captureTime(forSongPosition: songStart, heardAt: c),
              let captureEnd = clock.captureTime(forSongPosition: songEnd, heardAt: c)
        else { return nil }

        let key = "\(trackID)#\(lineIndex)"
        let streamStart = captureStart + source.streamOffset
        let streamEnd = captureEnd + source.streamOffset
        let snapshot = source.timeline.snapshot(from: streamStart, to: streamEnd)

        // 줄 전체가 분석됐으면 캐시 고정, 아니면 분석이 0.1초 이상 진행됐을 때만 다시 계산
        if let cached = wipeCache[key], cached.complete || snapshot.knownUntil - cached.knownUntil < 0.1 {
            return cached.wipe
        }
        let period = source.timeline.framePeriod
        let frames = snapshot.frames.map { frame in
            let streamTime = Double(frame.index) * period
            let voiced = frame.confidence >= 0.5 && frame.pitchHz > 0
            return VocalFrame(
                time: songStart + (streamTime - streamStart),
                voiced: voiced,
                midi: voiced ? NoteSegmenter.midi(fromHz: frame.pitchHz) : nil
            )
        }
        let wipe = SyllableAligner.align(text: text, frames: frames, framePeriod: period, lineStart: songStart, lineEnd: songEnd)
        wipeCache[key] = WipeCacheEntry(wipe: wipe, knownUntil: snapshot.knownUntil, complete: snapshot.knownUntil >= streamEnd)
        return wipe
    }
}

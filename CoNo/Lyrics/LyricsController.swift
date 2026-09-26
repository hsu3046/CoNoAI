// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// 가사 기능 조립: 플레이어 폴링 → 곡 위치 앵커(SongClock) → 곡별 가사 로드 → 화면 표시값 계산.
// 자동 싱크: 2초마다 최근 30초 보컬로 싱크 가사 후보들을 평가해 가장 잘 맞는 후보와 시각 오차를 적용한다
// (LRCLIB 가사는 곡마다 오차가 다르다 — First Love 는 약 1초 이르게 만들어져 있었다).
// 곡 정보·재생 위치는 지금 Apple Music 만 준다.

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
    /// 음악 앱의 재생 상태와 지금 캡처되는 곡 (0.5초 폴링). 들리는 곡은 `track(atCaptureTime:)`.
    private(set) var playerState: PlayerState?
    private(set) var currentTrack: TrackInfo?

    /// 진단: 연속 재생 중 (플레이어 위치 − 캡처 시각) 의 흔들림.
    /// 이 값이 일정해야 앵커가 믿을 만하다. 크게 흔들리면 플레이어 위치 보고 자체가 들쭉날쭉한 것.
    struct AnchorDiagnostics: Equatable {
        /// 최근 앵커의 (중앙값 대비) 편차 (초)
        var lastDeviation: Double = 0
        /// 최근 창의 최대 − 최소 (초)
        var range: Double = 0
        /// 창 안 앵커 수
        var count = 0
        /// 연속 재생 구간이 끊긴(되감기·곡 변경·큰 점프) 횟수
        var discontinuities = 0
    }
    private(set) var anchorDiagnostics = AnchorDiagnostics()
    @ObservationIgnored private var residualWindow: [Double] = []
    @ObservationIgnored private var lastResidualTrackID: String?
    /// 사용자가 맞추는 가사 싱크 (초). + 면 가사를 앞당긴다.
    var offsetSeconds: Double = 0

    /// 자동 싱크 상태 (화면 진단용)
    struct AutoSyncInfo: Equatable {
        /// 적용 중인 가사 지연 (초, + = 가사를 늦춤)
        var appliedDelay: Double = 0
        var lastEstimate: AutoSyncEstimate?
        var candidateIndex = 0
        var candidateCount = 0
    }
    private(set) var autoSync = AutoSyncInfo()

    /// 음악 앱 (재생 제어에도 쓴다)
    private let appleMusic = AppleMusicNowPlaying()
    /// 지금 곡 정보를 주는 쪽: 음악 앱이면 AppleScript, 그 밖의 앱은 macOS "지금 재생 중"
    private var provider: NowPlayingProvider?
    private let client = LRCLIBClient()
    private var clock = SongClock()

    /// 곡 하나의 가사 후보와 자동 싱크 상태
    private struct TrackLyrics {
        var candidates: [TimedLyrics]
        /// candidates 와 같은 순서의 LRCLIB id (학습값은 순번이 아니라 id 로 기억한다 — 캐시를 다시 받으면 순서가 바뀔 수 있다)
        var candidateIDs: [Int]
        var chosen = 0
        /// 적용 중인 가사 지연 (초)
        var appliedDelay = 0.0
        var hasDelay = false
        /// 큰 변화는 두 번 연속 같은 값이 나와야 적용
        var pendingDelay: Double?
        /// 넓게 찾기(영상 인트로 차이) 결과 — 두 번 연속 같으면 적용
        var pendingCoarseDelay: Double?
        var lastEstimate: AutoSyncEstimate?

        var lyrics: TimedLyrics? { candidates.indices.contains(chosen) ? candidates[chosen] : nil }
    }
    /// nil 값 = 싱크 가사 없음 (일반 가사만 있거나 못 찾음)
    private var lyricsByTrack: [String: TrackLyrics?] = [:]
    @ObservationIgnored private var lastHeardCaptureTime: Double?
    /// 화면에 실제로 쓰는 지연 (곡별). 자동 싱크가 값을 바꿔도 부르는 중인 줄에는 반영하지 않고
    /// 줄이 바뀌거나 간주일 때만 따라간다 → 줄 중간에 색칠이 앞뒤로 튀지 않는다.
    private struct DisplayCommit {
        var delay: Double
        var lineIndex: Int?
    }
    @ObservationIgnored private var displayCommits: [String: DisplayCommit] = [:]
    /// 한 줄 안에서 색칠이 뒤로 가지 않게 — 마지막으로 그린 (줄 식별, 칠한 글자 수)
    @ObservationIgnored private var lastHighlight: (line: String, characters: Double)?
    /// 곡별로 찾은 가사 지연을 기억 (다시 틀면 처음부터 맞춘 상태로 시작)
    private let learnedDelays = LearnedLyricsDelays()
    private var tracks: [String: TrackInfo] = [:]
    private var loadingTrackIDs: Set<String> = []
    /// 곡별 로드 실패 (횟수, 다시 시도할 시각). 실패를 기억하지 않으면 0.5초 폴링마다 다시 요청해
    /// 오프라인·레이트 리밋(429)에서 요청이 끝없이 나간다.
    @ObservationIgnored private var loadFailures: [String: (count: Int, retryAt: ContinuousClock.Instant)] = [:]
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

    /// 음악 앱인지 (AppleScript 로 곡 정보·재생 제어)
    static func isAppleMusic(bundleID: String?) -> Bool {
        bundleID == AppleMusicNowPlaying.bundleID
    }

    /// - Parameter captureTime: 호스트 시각 → 캡처 스트림 시각 (DelayPipeline 캡처 시계)
    func start(sourceBundleID: String?, captureTime: @escaping @MainActor (UInt64) -> Double?) {
        stop()
        if Self.isAppleMusic(bundleID: sourceBundleID) {
            provider = appleMusic
        } else if let remote = RemoteNowPlayingProvider(bundleID: sourceBundleID) {
            provider = remote
        } else {
            // 시스템 전체 캡처이거나 "지금 재생 중" 어댑터를 쓸 수 없다
            status = .unsupportedSource
            return
        }
        status = .waitingForPlayer
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce(captureTime: captureTime)
                tick += 1
                if tick % 4 == 0 { self.runAutoSync() }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        provider?.stop()
        provider = nil
        clock.reset()
        wipeCache.removeAll()
        residualWindow.removeAll()
        lastResidualTrackID = nil
        anchorDiagnostics = AnchorDiagnostics()
        lastHeardCaptureTime = nil
        displayCommits.removeAll()
        lastHighlight = nil
        autoSync = AutoSyncInfo()
        vocalSource = nil
        currentTrackID = nil
        playerState = nil
        currentTrack = nil
        status = .inactive
    }

    /// 음악 앱 재생·일시정지
    func send(_ command: PlayerCommand) async -> Result<Void, NowPlayingError> {
        await appleMusic.send(command)
    }

    /// 지금 곡의 앨범 아트 바이트 (화면 조명 색용)
    func currentArtworkData() async -> Data? {
        await provider?.artworkData()
    }

    /// 캡처 시각 c 의 소리(= 들리는 소리)가 속한 곡. 화면 제목용 — 상태를 바꾸지 않는다.
    func track(atCaptureTime c: Double) -> TrackInfo? {
        clock.position(atCaptureTime: c).flatMap { tracks[$0.trackID] }
    }

    private func pollOnce(captureTime: @MainActor (UInt64) -> Double?) async {
        guard let provider else { return }
        let result = await provider.poll()
        guard !Task.isCancelled else { return }
        switch result {
        case let .failure(error):
            status = .failed(error.localizedDescription)
        case let .success(sample):
            if playerState != sample.state { playerState = sample.state }
            if currentTrack != sample.track { currentTrack = sample.track }
            guard let capture = captureTime(sample.hostTime) else { return }
            recordResidual(sample: sample, captureTime: capture)
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
            if currentTrackID != track.id {
                // 음절 정렬 캐시는 지금 곡 것만 남긴다 (줄마다 쌓여 오래 쓰면 수십 MB)
                wipeCache = wipeCache.filter { $0.key.hasPrefix("\(track.id)#") }
            }
            currentTrackID = track.id
            let backingOff = loadFailures[track.id].map { ContinuousClock.now < $0.retryAt } ?? false
            if lyricsByTrack[track.id] == nil, !loadingTrackIDs.contains(track.id), !backingOff {
                load(track)
            } else if let known = statusByTrack[track.id] {
                status = known
            }
        }
    }

    /// 최근 30초(되감기 이후) 보컬로 싱크 가사 후보들을 평가해 후보 선택과 가사 지연을 갱신한다.
    private func runAutoSync() {
        guard let source = vocalSource, let c = lastHeardCaptureTime,
              let position = clock.position(atCaptureTime: c), position.isPlaying,
              let entry = lyricsByTrack[position.trackID], var trackLyrics = entry
        else { return }

        // 분석 창: 연속 재생 구간 안의 최근 30초 ~ 분석이 끝난 곳까지 (캡처 시각)
        let segmentStart = clock.continuousSegmentStart(heardAt: c) ?? c
        let windowStart = max(segmentStart, c - 30)
        // 끝은 창 시작 + 40초로 한정 (무한대를 넘기면 프레임 번호 변환에서 정수 오버플로로 크래시)
        let probe = source.timeline.snapshot(from: windowStart + source.streamOffset, to: windowStart + source.streamOffset + 40)
        let windowEnd = probe.knownUntil - source.streamOffset
        guard windowEnd - windowStart > 8 else { return }

        // 곡 시각 = 들리는 곡 위치 + (캡처 시각 − 들리는 캡처 시각)  (연속 재생 구간 안에서 선형)
        let period = source.timeline.framePeriod
        let frames = probe.frames.map { frame in
            let capture = Double(frame.index) * period - source.streamOffset
            let voiced = frame.confidence >= 0.5 && frame.pitchHz > 0
            return VocalFrame(time: position.seconds + (capture - c), voiced: voiced, midi: nil)
        }
        let songWindow = (position.seconds + (windowStart - c))...(position.seconds + (windowEnd - c))

        // 영상처럼 길이를 믿을 수 없는 곡은 처음에 ±30초로 넓게 찾고(인트로 길이 차), 그 뒤로는 적용 중인 지연 ±2.5초만 따라간다
        let coarse = tracks[position.trackID]?.durationIsReliable == false && !trackLyrics.hasDelay
        let center = trackLyrics.hasDelay ? trackLyrics.appliedDelay : 0
        let range: ClosedRange<Double> = coarse
            ? LyricsAutoSync.coarseRange
            : (center - LyricsAutoSync.trackingHalfWidth)...(center + LyricsAutoSync.trackingHalfWidth)
        let estimates: [AutoSyncEstimate?] = trackLyrics.candidates.map { lyrics in
            let starts = lyrics.lines
                .filter { line in
                    guard !line.isInterlude else { return false }
                    // 줄이 실제로 불릴 곡 시각 (= LRC + 지연) 이 분석 창에 들 수 있는 줄
                    return coarse
                        ? line.start >= songWindow.lowerBound - range.upperBound && line.start <= songWindow.upperBound - range.lowerBound
                        : songWindow.contains(line.start + center)
                }
                .map(\.start)
            return LyricsAutoSync.estimate(lineStarts: starts, frames: frames, framePeriod: period, searchRange: range)
        }

        // 후보 교체: 지금 후보보다 확실히 잘 맞는 후보가 있으면
        let usable: (AutoSyncEstimate?) -> Bool = { ($0?.confidence ?? 0) >= 0.4 && ($0?.lineCount ?? 0) >= 4 }
        if let bestIndex = estimates.indices.max(by: { (estimates[$0]?.score ?? 0) < (estimates[$1]?.score ?? 0) }),
           bestIndex != trackLyrics.chosen, usable(estimates[bestIndex]),
           (estimates[bestIndex]?.score ?? 0) > (estimates[trackLyrics.chosen]?.score ?? 0) + 0.08 {
            trackLyrics.chosen = bestIndex
            trackLyrics.hasDelay = false
            trackLyrics.pendingDelay = nil
            trackLyrics.pendingCoarseDelay = nil
        }

        // 넓게 찾기: 더 엄격하게 (신뢰도 0.5·5줄 이상) + 두 번 연속 0.3초 안에서 같은 값일 때만 — 엉뚱한 박자에 붙지 않게
        if coarse {
            if let estimate = estimates[trackLyrics.chosen], estimate.confidence >= 0.5, estimate.lineCount >= 5 {
                trackLyrics.lastEstimate = estimate
                if let pending = trackLyrics.pendingCoarseDelay, abs(pending - estimate.lyricsDelay) <= 0.3 {
                    trackLyrics.appliedDelay = estimate.lyricsDelay
                    trackLyrics.hasDelay = true
                    trackLyrics.pendingCoarseDelay = nil
                } else {
                    trackLyrics.pendingCoarseDelay = estimate.lyricsDelay
                }
            } else {
                trackLyrics.lastEstimate = estimates[trackLyrics.chosen]
            }
        } else if let estimate = estimates[trackLyrics.chosen], estimate.confidence >= 0.4 {
            // 지연 적용: 신뢰도 충분할 때만, 작은 변화는 부드럽게, 큰 변화는 두 번 연속 확인 후
            trackLyrics.lastEstimate = estimate
            let difference = abs(estimate.lyricsDelay - trackLyrics.appliedDelay)
            if !trackLyrics.hasDelay {
                trackLyrics.appliedDelay = estimate.lyricsDelay
                trackLyrics.hasDelay = true
            } else if difference <= 0.08 {
                // 체감되지 않는 차이는 따라가지 않는다 (잦은 미세 보정 방지)
                trackLyrics.pendingDelay = nil
            } else if difference <= 0.25 {
                trackLyrics.appliedDelay += (estimate.lyricsDelay - trackLyrics.appliedDelay) * 0.5
                trackLyrics.pendingDelay = nil
            } else if let pending = trackLyrics.pendingDelay, abs(pending - estimate.lyricsDelay) <= 0.1 {
                trackLyrics.appliedDelay = estimate.lyricsDelay
                trackLyrics.pendingDelay = nil
            } else {
                trackLyrics.pendingDelay = estimate.lyricsDelay
            }
        } else {
            trackLyrics.lastEstimate = estimates[trackLyrics.chosen]
        }

        lyricsByTrack[position.trackID] = .some(trackLyrics)
        if trackLyrics.hasDelay, let track = tracks[position.trackID], trackLyrics.candidateIDs.indices.contains(trackLyrics.chosen) {
            learnedDelays.store(delay: trackLyrics.appliedDelay, candidateID: trackLyrics.candidateIDs[trackLyrics.chosen], for: track)
        }
        autoSync = AutoSyncInfo(
            appliedDelay: trackLyrics.appliedDelay,
            lastEstimate: trackLyrics.lastEstimate,
            candidateIndex: trackLyrics.chosen,
            candidateCount: trackLyrics.candidates.count
        )
    }

    private func recordResidual(sample: NowPlayingSample, captureTime: Double) {
        guard sample.state == .playing, let trackID = sample.track?.id else { return }
        let residual = sample.position - captureTime
        let median = residualWindow.sorted().dropFirst(residualWindow.count / 2).first
        // 곡이 바뀌었거나 2초 넘게 튀면 새 연속 구간 (되감기·건너뛰기)
        if trackID != lastResidualTrackID || median.map({ abs(residual - $0) > 2 }) ?? false {
            if lastResidualTrackID != nil { anchorDiagnostics.discontinuities += 1 }
            residualWindow.removeAll()
            lastResidualTrackID = trackID
        }
        residualWindow.append(residual)
        if residualWindow.count > 40 { residualWindow.removeFirst() } // 약 20초
        let sorted = residualWindow.sorted()
        let center = sorted[sorted.count / 2]
        anchorDiagnostics.lastDeviation = residual - center
        anchorDiagnostics.range = (sorted.last ?? 0) - (sorted.first ?? 0)
        anchorDiagnostics.count = sorted.count
    }

    private func load(_ track: TrackInfo) {
        loadingTrackIDs.insert(track.id)
        status = .loading(track)
        Task { [weak self] in
            guard let self else { return }
            let outcome: Status
            do {
                switch try await client.lyrics(for: track) {
                case let .synced(candidates):
                    let usable = candidates
                        .compactMap { candidate in candidate.syncedLyrics.map { (id: candidate.id, lyrics: LRCParser.parse($0)) } }
                        .filter { !$0.lyrics.lines.isEmpty }
                    let parsed = usable.map(\.lyrics)
                    var trackLyrics = TrackLyrics(candidates: parsed, candidateIDs: usable.map(\.id))
                    if let learned = learnedDelays.load(for: track),
                       let index = learned.candidateIndex(in: trackLyrics.candidateIDs) {
                        trackLyrics.chosen = index
                        trackLyrics.appliedDelay = learned.delay
                        trackLyrics.hasDelay = true
                    }
                    lyricsByTrack[track.id] = parsed.isEmpty ? .some(nil) : .some(trackLyrics)
                    outcome = .ready(track, synced: !parsed.isEmpty)
                case .plainOnly:
                    lyricsByTrack[track.id] = .some(nil)
                    outcome = .ready(track, synced: false)
                case .notFound:
                    lyricsByTrack[track.id] = .some(nil)
                    outcome = .notFound(track)
                }
                statusByTrack[track.id] = outcome
                loadFailures[track.id] = nil
            } catch {
                // 5초 → 10 → 20 → 40 → 60초 간격으로 다시 시도 (그동안은 실패 상태를 유지)
                let count = (loadFailures[track.id]?.count ?? 0) + 1
                let wait = min(5 * pow(2, Double(count - 1)), 60)
                loadFailures[track.id] = (count, ContinuousClock.now + .seconds(wait))
                outcome = .failed("\(error.localizedDescription) — \(Int(wait))초 뒤 다시 시도합니다")
                statusByTrack[track.id] = outcome
            }
            loadingTrackIDs.remove(track.id)
            if currentTrackID == track.id { status = outcome }
        }
    }

    /// 캡처 시각 c 의 소리(= 지금 귀에 들리는 소리)에 맞는 가사 표시값.
    func display(atCaptureTime c: Double) -> (track: TrackInfo?, lyrics: LyricsDisplay?) {
        lastHeardCaptureTime = c
        guard let position = clock.position(atCaptureTime: c) else { return (nil, nil) }
        let track = tracks[position.trackID]
        guard let entry = lyricsByTrack[position.trackID], let trackLyrics = entry, let lyrics = trackLyrics.lyrics else { return (track, nil) }

        // 가사 시각 이동 = 사용자 미세조정(+ 앞당김) − 자동 싱크 지연(+ 늦춤)
        // 지연은 줄 사이에서만 새 값으로 바꾼다 (부르는 중인 줄은 시작할 때의 값을 유지)
        var commit = displayCommits[position.trackID] ?? DisplayCommit(delay: trackLyrics.appliedDelay, lineIndex: nil)
        var t = position.seconds + offsetSeconds - commit.delay
        let lineNow = lyrics.lineIndex(at: t)
        if commit.delay != trackLyrics.appliedDelay, lineNow == nil || lineNow != commit.lineIndex {
            commit.delay = trackLyrics.appliedDelay
            t = position.seconds + offsetSeconds - commit.delay
        }
        commit.lineIndex = lyrics.lineIndex(at: t)
        displayCommits[position.trackID] = commit
        let shift = offsetSeconds - commit.delay
        var display = LyricsDisplay()
        if let index = lyrics.lineIndex(at: t) {
            let line = lyrics.lines[index]
            let end = lyrics.end(of: index)
            display.current = line.text
            display.progress = end > line.start ? min(max((t - line.start) / (end - line.start), 0), 1) : 1
            display.next = lyrics.nextLineIndex(after: line.start).map { lyrics.lines[$0].text }
            if let wipe = lineWipe(trackID: position.trackID, candidate: trackLyrics.chosen, lineIndex: index, text: line.text,
                                   songStart: line.start - shift, songEnd: end - shift, heardAt: c) {
                // 음절 타이밍은 소리에서 잰 실제 곡 시각이라 사용자 오프셋 없이 비교한다
                var characters = wipe.highlightedCharacters(at: position.seconds)
                // 분석 진행에 따른 재정렬·곡 위치 미세 흔들림으로 뒤로 물러나지 않게 한다.
                // 크게(1.5글자 넘게) 뒤로 가면 되감기 같은 실제 변화로 보고 따른다.
                let lineID = "\(position.trackID)#\(trackLyrics.chosen)#\(index)"
                if let last = lastHighlight, last.line == lineID, characters < last.characters, last.characters - characters < 1.5 {
                    characters = last.characters
                }
                lastHighlight = (lineID, characters)
                display.highlightedCharacters = characters
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
    private func lineWipe(trackID: String, candidate: Int, lineIndex: Int, text: String, songStart: Double, songEnd: Double, heardAt c: Double) -> LineWipe? {
        guard let source = vocalSource,
              let captureStart = clock.captureTime(forSongPosition: songStart, heardAt: c),
              let captureEnd = clock.captureTime(forSongPosition: songEnd, heardAt: c)
        else { return nil }

        // 후보·이동량이 바뀌면 다른 키 (이동량은 50 ms 단위)
        let key = "\(trackID)#\(candidate)#\(lineIndex)#\(Int((songStart * 20).rounded()))"
        let streamStart = captureStart + source.streamOffset
        let streamEnd = captureEnd + source.streamOffset

        // 줄 전체가 분석됐으면 캐시 고정, 아니면 분석이 0.1초 이상 진행됐을 때만 다시 계산.
        // 매 프레임 불리므로 프레임 배열을 복사하기 전에 분석 전선만 보고 판단한다.
        if let cached = wipeCache[key], cached.complete || source.timeline.knownUntil - cached.knownUntil < 0.1 {
            return cached.wipe
        }
        let snapshot = source.timeline.snapshot(from: streamStart, to: streamEnd)
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
        // 분석 전선 (곡 시각) — 줄 뒷부분이 아직 분석 전이면 정렬기가 임시 구간으로 채운다
        let analyzedSong = songStart + (snapshot.knownUntil - streamStart)
        let wipe = SyllableAligner.align(text: text, frames: frames, framePeriod: period,
                                         lineStart: songStart, lineEnd: songEnd, analyzedUntil: analyzedSong)
        wipeCache[key] = WipeCacheEntry(wipe: wipe, knownUntil: snapshot.knownUntil, complete: snapshot.knownUntil >= streamEnd)
        return wipe
    }
}

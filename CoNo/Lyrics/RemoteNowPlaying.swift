// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// 음악 앱이 아닌 앱(브라우저의 YouTube 등)의 곡 정보·재생 위치. macOS "지금 재생 중" 을
// mediaremote-adapter `stream` (오래 사는 perl 프로세스 하나) 으로 받아, 연결된 앱의 것만 쓴다.
// 재생 위치 = elapsedTime + (지금 − timestamp) × playbackRate — 음악 앱 폴링과 같은 NowPlayingSample 로 바꿔 준다.

import Foundation
import Synchronization

/// 곡 정보·재생 위치를 주는 쪽 (음악 앱 AppleScript / "지금 재생 중")
protocol NowPlayingProvider: AnyObject, Sendable {
    func poll() async -> Result<NowPlayingSample, NowPlayingError>
    func artworkData() async -> Data?
    func stop()
}

extension AppleMusicNowPlaying: NowPlayingProvider {
    func stop() {}
}

final class RemoteNowPlayingProvider: NowPlayingProvider {
    private struct State {
        var info: RemoteNowPlaying?
        var artwork: Data?
    }

    /// 스트림 스레드가 쓰고 poll 이 읽는다 (Mutex 는 복사할 수 없어 클래스로 감싸 클로저에 넘긴다)
    private final class SharedState: Sendable {
        let mutex = Mutex(State())
    }

    private let bundleID: String
    private let stream: MediaRemoteStream
    private let state = SharedState()

    init?(bundleID: String?) {
        guard let bundleID, let bridge = MediaRemoteBridge.shared else { return nil }
        self.bundleID = bundleID
        let state = self.state
        stream = MediaRemoteStream(bridge: bridge) { info, artwork in
            state.mutex.withLock { current in
                // 곡이 바뀌면 이전 곡 아트는 버린다 (새 아트는 조금 늦게 오는 경우가 많다)
                if current.info?.title != info?.title { current.artwork = nil }
                current.info = info
                if let artwork { current.artwork = artwork }
            }
        }
        stream.start()
    }

    func stop() {
        stream.stop()
    }

    func poll() async -> Result<NowPlayingSample, NowPlayingError> {
        let hostTime = mach_absolute_time()
        let now = Date().timeIntervalSince1970
        let info = state.mutex.withLock { $0.info }
        // 다른 앱이 "지금 재생 중" 이면 이 앱은 곡 정보가 없는 것으로 본다
        guard let info, info.belongs(to: bundleID) else {
            return .success(NowPlayingSample(state: .stopped, track: nil, position: 0, hostTime: hostTime))
        }
        let rate = info.playing ? (info.playbackRate ?? 1) : 0
        let elapsed = (info.elapsedTimeMicros ?? 0) / 1_000_000
        let stamp = (info.timestampEpochMicros ?? now * 1_000_000) / 1_000_000
        let position = max(0, elapsed + (now - stamp) * rate)
        let duration = (info.durationMicros ?? 0) / 1_000_000
        let cleaned = MediaTitleCleaner.clean(title: info.title, artist: info.artist ?? "")
        let track = TrackInfo(
            // 같은 영상을 다시 틀어도 같은 ID (가사 캐시·학습값과 같은 기준)
            id: "\(info.bundleIdentifier)|\(info.title)|\(info.artist ?? "")|\(Int(duration.rounded()))",
            title: cleaned.title,
            artist: cleaned.artist,
            album: info.album ?? "",
            duration: duration,
            // 브라우저 영상은 원곡과 길이가 다를 수 있다 (음악 앱류는 음원 그대로)
            durationIsReliable: false
        )
        return .success(NowPlayingSample(state: info.playing ? .playing : .paused, track: track, position: position, hostTime: hostTime))
    }

    func artworkData() async -> Data? {
        state.mutex.withLock { current in
            current.info?.belongs(to: bundleID) == true ? current.artwork : nil
        }
    }
}

/// `stream --micros --no-diff` 를 읽는 백그라운드 프로세스. 죽으면 잠시 뒤 다시 띄운다.
final class MediaRemoteStream: @unchecked Sendable {
    typealias Handler = @Sendable (RemoteNowPlaying?, Data?) -> Void

    private let bridge: MediaRemoteBridge
    private let handler: Handler
    private let lock = NSLock()
    private var process: Process?
    private var buffer = Data()
    private var stopped = false
    private var restartDelay: TimeInterval = 1

    init(bridge: MediaRemoteBridge, handler: @escaping Handler) {
        self.bridge = bridge
        self.handler = handler
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, process == nil else { return }
        let process = bridge.makeProcess(["stream", "--micros", "--no-diff", "--debounce=100"])
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
        process.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            self?.restartLater()
        }
        do {
            try process.run()
            self.process = process
        } catch {
            restartDelay = min(restartDelay * 2, 30)
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let process = self.process
        self.process = nil
        lock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }

    private func restartLater() {
        lock.lock()
        process = nil
        buffer.removeAll()
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, 30)
        let shouldRestart = !stopped
        lock.unlock()
        guard shouldRestart else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in self?.start() }
    }

    /// 줄 단위 JSON: {"type":"data","diff":false,"payload":{...}} — 빈 payload = 재생 중인 미디어 없음
    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        var lines: [Data] = []
        lock.lock()
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer.subdata(in: buffer.startIndex..<newline))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        if !lines.isEmpty { restartDelay = 1 }
        lock.unlock()
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = object["payload"] as? [String: Any]
            else { continue }
            let artwork = (payload["artworkData"] as? String).flatMap { Data(base64Encoded: $0) }
            var fields = payload
            fields.removeValue(forKey: "artworkData")
            let info = (try? JSONSerialization.data(withJSONObject: fields))
                .flatMap { try? JSONDecoder().decode(RemoteNowPlaying.self, from: $0) }
            handler(info, artwork)
        }
    }
}

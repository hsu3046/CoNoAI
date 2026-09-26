// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import Foundation

/// 곡별 가사 지연·후보 기억 (UserDefaults). 키는 제목·아티스트·길이 — LRCLIB 캐시 키와 같은 기준.
struct LearnedLyricsDelays {
    struct Learned: Equatable {
        let delay: Double
        /// 후보 식별자 ("netease:625096"). 옛 형식(LRCLIB 번호만)은 "lrclib:번호" 로 읽는다.
        let candidateKey: String?
        /// 더 옛 형식(후보 순번). 식별자가 없을 때만 쓴다.
        let legacyIndex: Int?

        /// 지금 후보 목록에서 기억한 후보의 위치. 기억한 후보가 목록에 없으면 nil (지연도 적용하지 않는다 — 다른 가사일 수 있다).
        func candidateIndex(in keys: [String]) -> Int? {
            if let candidateKey { return keys.firstIndex(of: candidateKey) }
            if let legacyIndex, keys.indices.contains(legacyIndex) { return legacyIndex }
            return nil
        }
    }

    private let defaults: UserDefaults
    private static let prefix = "space.knowai.cono.lyricsDelay."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(for track: TrackInfo) -> String {
        "\(Self.prefix)\(track.title)|\(track.artist)|\(Int(track.duration.rounded()))"
    }

    func load(for track: TrackInfo) -> Learned? {
        guard let value = defaults.dictionary(forKey: key(for: track)), let delay = value["delay"] as? Double else { return nil }
        let key = value["candidateKey"] as? String ?? (value["candidateID"] as? Int).map { "\(LyricsSource.lrclib.rawValue):\($0)" }
        return Learned(delay: delay, candidateKey: key, legacyIndex: value["candidate"] as? Int)
    }

    /// 곡별로 기억한 가사 지연을 모두 지운다
    func removeAll() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.prefix) {
            defaults.removeObject(forKey: key)
        }
    }

    func store(delay: Double, candidateKey: String, for track: TrackInfo) {
        defaults.set(["delay": delay, "candidateKey": candidateKey], forKey: key(for: track))
    }
}

// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later

import Foundation

/// 곡별 가사 지연·후보 기억 (UserDefaults). 키는 제목·아티스트·길이 — LRCLIB 캐시 키와 같은 기준.
struct LearnedLyricsDelays {
    struct Learned: Equatable {
        let delay: Double
        /// LRCLIB 후보 id
        let candidateID: Int?
        /// 옛 형식(후보 순번). id 가 없을 때만 쓴다.
        let legacyIndex: Int?

        /// 지금 후보 목록에서 기억한 후보의 위치. 기억한 후보가 목록에 없으면 nil (지연도 적용하지 않는다 — 다른 가사일 수 있다).
        func candidateIndex(in ids: [Int]) -> Int? {
            if let candidateID { return ids.firstIndex(of: candidateID) }
            if let legacyIndex, ids.indices.contains(legacyIndex) { return legacyIndex }
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
        return Learned(delay: delay, candidateID: value["candidateID"] as? Int, legacyIndex: value["candidate"] as? Int)
    }

    /// 곡별로 기억한 가사 지연을 모두 지운다
    func removeAll() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.prefix) {
            defaults.removeObject(forKey: key)
        }
    }

    func store(delay: Double, candidateID: Int, for track: TrackInfo) {
        defaults.set(["delay": delay, "candidateID": candidateID], forKey: key(for: track))
    }
}

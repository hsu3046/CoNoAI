// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later

import Foundation

/// 플레이어가 알려 준 곡 정보 (가사 조회·캐시·학습값의 키)
struct TrackInfo: Hashable, Sendable {
    /// 음악 앱의 persistent ID (곡 변경 감지·가사 캐시 키)
    let id: String
    let title: String
    let artist: String
    let album: String
    /// 초
    let duration: Double
}

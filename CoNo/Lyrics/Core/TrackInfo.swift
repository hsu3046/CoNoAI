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
    /// 길이가 원곡 음원과 같다고 믿을 수 있는지. 영상(MV·라이브)은 인트로·아웃트로로 달라서 false —
    /// 가사 검색이 길이 조건을 풀고, 자동 싱크가 처음에 넓게 찾는다.
    var durationIsReliable = true
}

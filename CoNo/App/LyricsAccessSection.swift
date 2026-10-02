// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import SwiftUI

/// Last actual request, including a cache hit, rather than a speculative connection test.
struct LyricsAccessSection: View {
    let engine: KaraokeEngine
    let settings: AppSettings
    private let monitor = LyricsServiceMonitor.shared

    var body: some View {
        Section("외부 서비스 연결 상태") {
            ForEach(LyricsServiceID.allCases, id: \.self) { service in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(service.label)
                        Spacer()
                        Text(summary(service)).foregroundStyle(.secondary)
                    }
                    if enabled(service), case let .failed(issue) = monitor.snapshots[service]?.state {
                        Text(issue.localizedDescription)
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Button("현재 곡 다시 검색") { engine.lyrics.retryOnlineLyrics() }
                .disabled(engine.lyrics.currentTrack == nil || engine.lyrics.isChangingLocalLyrics || isLoading)
            if engine.lyrics.localLyricsInfo != nil {
                note("직접 적용한 내 가사를 우선 사용합니다. 온라인 검색으로 바꾸려면 아래에서 내 가사를 해제해 주세요.")
            } else {
                note("최근 요청 결과입니다. 요청 제한의 대기 시간이 지나면 다시 검색할 수 있어요. 서비스가 응답하지 않아도 보관함의 내 가사는 사용할 수 있습니다.")
            }
        }
        Section("서비스 이용 조건") {
            note("LRCLIB은 API 키 없이 조회합니다. 보관함에서 공개할 가사와 곡 정보를 검토하고 직접 공개 버튼을 눌러야 전송됩니다.")
            note("NetEase는 비공식 연결, AMLL은 공개 커뮤니티 자료를 사용합니다. 지역이나 서비스 변경에 따라 조회가 제한될 수 있어요.")
            note("Apple Music은 본인 계정 연결과 해당 지역에서 이용 가능한 구독이 필요합니다. 가사 연결은 비공식 방식이므로 연결해도 모든 곡의 가사를 보장하지 않습니다.")
            note("QQ·Kugou는 보유한 QRC·KRC 파일을 가져와 사용할 수 있습니다. Musixmatch 온라인 연동은 공식 API 이용 권한과 키를 준비한 뒤 추가할 수 있어요.")
        }
    }

    private var isLoading: Bool {
        if case .loading = engine.lyrics.status { return true }
        return false
    }

    private func enabled(_ service: LyricsServiceID) -> Bool {
        switch service {
        case .lrclib: true
        case .netease: settings.lyricsNetEase
        case .amll: settings.lyricsAMLL
        case .appleMusic: settings.lyricsAppleMusic
        }
    }

    private func summary(_ service: LyricsServiceID) -> String {
        guard enabled(service) else { return "꺼짐" }
        switch monitor.snapshots[service]?.state {
        case .none, .idle: return "요청 전"
        case .loading: return "요청 중…"
        case .reachable: return "응답 확인"
        case .cached: return "저장된 검색 결과 사용"
        case .failed: return "확인 필요"
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

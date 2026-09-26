// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 메인 화면과 설정 창이 함께 쓰는 사용자 설정 (UserDefaults 에 저장).
// 실행 중인 엔진 값(키·가이드 보컬 등)은 엔진이 원본이고, 여기는 "다음 시작 때 쓸 값"과 기본값이다.

import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    /// 캡처할 앱: "auto"(음악 앱 우선, 없으면 재생 중인 앱) | 번들 ID | "system"
    var sourcePreference: String { didSet { store(sourcePreference, "sourcePreference") } }
    var mode: ProcessingMode { didSet { store(mode.rawValue, "mode") } }
    var delaySeconds: Double { didSet { store(delaySeconds, "delaySeconds") } }
    var muteOriginal: Bool { didSet { store(muteOriginal, "muteOriginal") } }
    var backend: InferenceBackend { didSet { store(backend.rawValue, "backend") } }
    var stepSeconds: Double { didSet { store(stepSeconds, "stepSeconds") } }
    var rightContextSeconds: Double { didSet { store(rightContextSeconds, "rightContextSeconds") } }
    /// 음악 앱에서 노래가 나오면 바로 시작
    var autoStart: Bool { didSet { store(autoStart, "autoStart") } }
    /// 가이드 보컬 기본값 (0…0.5)
    var guideVocalLevel: Double { didSet { store(guideVocalLevel, "guideVocalLevel") } }
    /// 화면을 소리보다 늦출 시간 (블루투스 등)
    var displayLatencyMilliseconds: Double { didSet { store(displayLatencyMilliseconds, "displayLatencyMilliseconds") } }
    /// 음정 바에 진단 숫자 표시
    var showPitchDiagnostics: Bool { didSet { store(showPitchDiagnostics, "showPitchDiagnostics") } }
    /// 음정 바 세로 범위를 곡 음역에 맞춰 자동으로 넓히고 좁힌다 (끄면 A2–A5 고정)
    var pitchAutoZoom: Bool { didSet { store(pitchAutoZoom, "pitchAutoZoom") } }
    /// LRCLIB 말고 함께 찾을 가사 소스
    var lyricsNetEase: Bool { didSet { store(lyricsNetEase, "lyricsNetEase") } }
    var lyricsAMLL: Bool { didSet { store(lyricsAMLL, "lyricsAMLL") } }
    /// Apple Music 음절 가사 (비공개 엔드포인트 — 기본 꺼짐, 계정 연결 필요)
    var lyricsAppleMusic: Bool { didSet { store(lyricsAppleMusic, "lyricsAppleMusic") } }
    /// 내 목소리 — "내 키" 버튼이 곡을 이 목소리에 맞춘다
    var myVoice: VoiceType { didSet { store(myVoice.rawValue, "myVoice") } }
    /// 음표 막대 외에 원곡 가수의 음정 곡선도 그린다
    var showPitchContour: Bool { didSet { store(showPitchContour, "showPitchContour") } }

    static let autoSource = "auto"
    static let systemSource = "system"

    private let defaults: UserDefaults
    private static let prefix = "space.knowai.cono.settings."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func value<T>(_ key: String, _ fallback: T) -> T { defaults.object(forKey: Self.prefix + key) as? T ?? fallback }
        sourcePreference = value("sourcePreference", Self.autoSource)
        mode = ProcessingMode(rawValue: value("mode", ProcessingMode.aiSeparation.rawValue)) ?? .aiSeparation
        delaySeconds = value("delaySeconds", 3.5)
        muteOriginal = value("muteOriginal", true)
        backend = InferenceBackend(rawValue: value("backend", InferenceBackend.coreMLAll.rawValue)) ?? .coreMLAll
        stepSeconds = value("stepSeconds", 1.0)
        rightContextSeconds = value("rightContextSeconds", 1.0)
        autoStart = value("autoStart", true)
        guideVocalLevel = value("guideVocalLevel", 0.0)
        displayLatencyMilliseconds = value("displayLatencyMilliseconds", 0.0)
        showPitchDiagnostics = value("showPitchDiagnostics", false)
        pitchAutoZoom = value("pitchAutoZoom", true)
        showPitchContour = value("showPitchContour", true)
        myVoice = VoiceType(rawValue: value("myVoice", VoiceType.male.rawValue)) ?? .male
        lyricsNetEase = value("lyricsNetEase", true)
        lyricsAMLL = value("lyricsAMLL", true)
        lyricsAppleMusic = value("lyricsAppleMusic", false)
    }

    var extraLyricsSources: Set<LyricsSource> {
        var sources: Set<LyricsSource> = []
        if lyricsNetEase { sources.insert(.netease) }
        if lyricsAMLL { sources.insert(.amll) }
        if lyricsAppleMusic { sources.insert(.appleMusic) }
        return sources
    }

    var separation: SeparationSettings {
        SeparationSettings(backend: backend, stepSeconds: stepSeconds, rightContextSeconds: rightContextSeconds)
    }

    /// 지금 캡처할 소스. auto 면 음악 앱 → 재생 중인 앱 순.
    func resolveSource(in sources: [AudioSource]) -> AudioSource? {
        switch sourcePreference {
        case Self.systemSource:
            return sources.first { $0.kind == .systemWide }
        case Self.autoSource:
            let apps = sources.filter { $0.kind != .systemWide }
            return apps.first { $0.bundleID == AppleMusicNowPlaying.bundleID && $0.isPlaying }
                ?? apps.first { $0.isPlaying }
                ?? apps.first { $0.bundleID == AppleMusicNowPlaying.bundleID }
        default:
            return sources.first { $0.bundleID == sourcePreference }
        }
    }

    private func store(_ value: Any, _ key: String) {
        defaults.set(value, forKey: Self.prefix + key)
    }
}

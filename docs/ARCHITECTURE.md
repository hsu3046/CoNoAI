# CoNo 아키텍처

스트리밍 앱(멜론·Apple Music·YouTube Music 등)의 소리를 가로채 홈 노래방으로 바꾸는 macOS 네이티브 앱.

## 전체 흐름 (목표)

```
[스트리밍 앱 재생]
   │ Core Audio process tap (muteBehavior = mutedWhenTapped → 원본은 스피커로 안 나감)
   ▼
[captureRing] ──▶ 워커: 보컬 분리 → 반주 / 보컬
   │                       └─ 보컬 → 음정 추출 → 음표 → 음정 바·채점 기준
   ▼
[playbackRing] ── N초 쌓인 뒤 재생 (지연 = 분석 시간 + 음정 미리보기 여유)
   ▼
[출력 장치]         [마이크] → 실시간 음정 → 채점
```

## 현재 구현 (PoC ① 캡처 + PoC ② AI 분리)

| 파일 | 역할 |
|---|---|
| `CoNo/Audio/CoreAudioUtils.swift` | HAL 프로퍼티 읽기 헬퍼 (AudioCap 기반) |
| `CoNo/Audio/AudioSourceCatalog.swift` | HAL 오디오 프로세스를 "책임 프로세스" 기준으로 사용자 앱에 묶어 목록화 |
| `CoNo/Audio/ProcessTapSession.swift` | 탭 + **탭만 넣은** 비공개 애그리게이트(캡처 전용, 탭 원래 레이트) 생성/정리 |
| `CoNo/Audio/PlaybackOutput.swift` | 재생: AVAudioEngine + AVAudioSourceNode (출력 장치 하드웨어 레이트), 장치 변경 감지 |
| `CoNo/Audio/SPSCRingBuffer.swift` | lock-free SPSC 링 버퍼 (`Synchronization.Atomic`) |
| `CoNo/Audio/DelayPipeline.swift` | 캡처 콜백 / 재생 콜백 / 워커 처리 + 프리롤 지연 + 재생 시계 + IO 진단 |
| `CoNo/Audio/StreamProcessor.swift` / `StreamProcessors.swift` | 처리 프로토콜·기본 패스스루/L−R와 AI 분리 구현 |
| `CoNo/Audio/AudioResampler.swift` | 샘플레이트 변환 1~2채널 (장치 ↔ 44.1k, 보컬 → 16k 모노). AVAudioConverter, 워커 전용 |
| `CoNo/DSP/STFT.swift` | torch.stft/istft 호환 STFT (reflect 패딩, periodic Hann, vDSP DFT) |
| `CoNo/DSP/StreamingSeparator.swift` | 고정 길이 창 모델을 연속 스트림에 쓰는 슬라이딩 윈도우 + 크로스페이드 |
| `CoNo/Separation/MDXSeparator.swift` | UVR MDX-Net ONNX 래퍼 (ONNX Runtime + CoreML EP) |
| `CoNo/DSP/PitchFrameStream.swift` | 프레임 음정 검출기 스트리밍 (SwiftF0 규칙: 룩어헤드 10 · 문맥 11 프레임) |
| `CoNo/DSP/NoteSegmenter.swift` | 음정 곡선 → 반음 음표 (중앙값·비브라토 흡수·짧은 음 제거·병합) |
| `CoNo/Separation/SwiftF0Detector.swift` | SwiftF0 ONNX 래퍼 (16 kHz, 16 ms 프레임, CPU) |
| `CoNo/Separation/PitchTracking.swift` | 보컬 → 16k 모노 → SwiftF0 → `PitchTimeline` (UI 가 읽는 스레드 안전 기록) |
| `CoNo/App/PitchBarView.swift` | 귀렌찬 스타일 음정 바 (TimelineView + Canvas, 60fps) |
| `CoNo/Audio/KaraokeEngine.swift` | UI 파사드 (모델 로드·벤치마크·자가진단, 시작/정지, 통계 폴링, 재생 위치) |
| `CoNoTests/DSPTests.swift` | STFT torch 일치·왕복, 슬라이딩 윈도우 정렬 테스트 |
| `CoNoTests/PitchTests.swift` | 음정 스트리밍 연속성·문맥, 음표 묶기 테스트 |
| `CoNo/Lyrics/ExtraLyricsSources.swift` | LRCLIB 외 가사 후보: NetEase 云音乐 · AMLL TTML DB (캐시 포함) |
| `CoNo/Lyrics/AppleMusicCatalog.swift` | Apple Music 음절 가사 (선택): 개발자 토큰 추출·카탈로그 검색·TTML, 사용자 토큰은 키체인 |
| `CoNo/App/AppleMusicConnection.swift` | Apple Music 계정 연결 창 (Apple 로그인 페이지 → 쿠키의 토큰만 저장) |
| `CoNo/Lyrics/Core/LyricsSources.swift` | 소스 구분, NetEase 크레딧 줄 제거, TTML → LRC, AMLL 색인 찾기 |
| `CoNo/Lyrics/RemoteNowPlaying.swift` | 음악 앱이 아닌 앱의 곡 정보·재생 위치·아트 ("지금 재생 중" 스트림 → `NowPlayingProvider`) |
| `CoNo/Lyrics/MediaRemoteBridge.swift` | 번들의 mediaremote-adapter 를 `/usr/bin/perl` 로 실행 (get/send) |
| `CoNo/Lyrics/Core/MediaTitleCleaner.swift` | 영상 제목·채널명 → 곡 제목·가수 |
| `CoNo/DSP/SmartKey.swift` | 남자키·여자키: 원곡 보컬 음역(유성 프레임 중앙값) → 옥타브 접은 키 (−6…+6) |
| `CoNo/App/KaraokeScreen.swift` | 메인 무대 화면 (헤더·음정 바·가사·도크, 시작 전 화면, 단축키, 전체화면 무대 모드, 자동 시작) |
| `CoNo/App/ControlDock.swift` | 재생·일시정지 · 키 ♭/♯ · 원키/남자키/여자키 · 반주/보컬/원곡 (+ 반주일 때 가이드 보컬) · 끝내기 |
| `CoNo/App/SettingsView.swift` | 설정 창 (⌘,): 일반(연결·자동 시작·내 목소리·권한) · 소리 · 가사(싱크·출처·캐시 지우기) · AI 엔진 · 진단(모니터·녹음 저장) · 정보 |
| `CoNo/App/AppSettings.swift` | UserDefaults 설정 (소스·모드·지연·AI·자동 시작·가이드 보컬·화면 싱크) |
| `CoNo/App/ArtworkStore.swift` | 곡별 앨범 아트(AppleScript `raw data`) + 무대 조명 색 추출 |
| `CoNo/App/StageTheme.swift` | 무대 색·글꼴, 배경(그라데이션 + 흐린 앨범 아트 + 반주 세기에 숨쉬는 조명) |

### 스레드 모델
- **캡처 IO 스레드** (탭 애그리게이트 IOProc, 탭 레이트): 탭 입력 → `captureRing`. 할당·락·로그 금지.
- **재생 렌더 스레드** (AVAudioSourceNode, 장치 레이트): `playbackRing` → 출력 + 재생 시계(seqlock). 할당·락·로그 금지.
- 탭 레이트 ≠ 장치 레이트면 변환은 워커가 한다 (`ResamplingProcessor` / `SeparationProcessor` 의 up/down 샘플러).
  예전 단일 애그리게이트(출력 장치 + 탭) 구성은 레이트가 다르면 HAL 드리프트 보정이 2배 변환을 떠맡아 틱이 났다.
- **워커 스레드**: `captureRing` 에서 1024 프레임씩 읽어 `StreamProcessor` 로 처리 후 `playbackRing` 에 씀. AI 분리는 여기서 step 마다 추론(약 0.2초)하며, 그동안 캡처는 링에 계속 쌓인다.
- **메인 스레드**: 50ms 마다 `takeStats()` 로 레벨·버퍼 상태 갱신.

### AI 분리 (UVR-MDX-NET Karaoke 2)
- 모델: 44.1kHz, n_fft 5120, hop 1024, dim_f 2048, dim_t 256 → 한 창 = 261,120 샘플(약 5.9초). 출력 = 반주(코러스 포함), 보컬 = 원곡 − 반주 × 1.065.
- 전처리 순서는 python-audio-separator `MDXSeparator.run_model` 과 동일: STFT → `[L re, L im, R re, R im]` → 저주파 3빈 0 → 모델 → iSTFT.
- 슬라이딩 윈도우: `step` 마다 최근 창 전체를 분리하고, 창 끝에서 `rightContext` 앞의 `step` 구간만 사용.
  - 출력 위치 오프셋 = `rightContext` (출력 o = 입력 o − rightContext) → 가사·음정 싱크 기준
  - 최대 대기 = `rightContext + step` + 추론 시간 → 프리롤(지연)은 이보다 길어야 함
- 실측 (M1 Pro, Release): CoreML 추론 1회 약 210ms (모델 150 + STFT 60). CPU 는 약 14초로 실시간 불가.

### 음정 바 (SwiftF0)
- 보컬(원곡 − 반주 × 1.065)을 들려줄 출력과 무관하게 항상 계산 → 16 kHz 모노 → SwiftF0 → 16 ms 프레임.
- **시간축은 하나: 처리기 출력 스트림의 초.** 음정 프레임 i = i × 16 ms, 재생 위치 = 재생 링에서 실제로 꺼낸 프레임 수 / 장치 레이트.
  - 재생 시계는 IO 콜백이 (재생한 프레임 수, 출력 호스트 시각)을 seqlock 으로 기록 → UI 가 경과 시간으로 보간.
  - 언더런 중엔 재생 프레임이 늘지 않으므로 화면도 멈춘다 (어긋나지 않음). 리샘플러 군지연(수 ms)은 무시.
- 미리보기 거리 ≈ 지연 − step − 추론 시간 − 160 ms(SwiftF0 룩어헤드). 화면 싱크 보정 슬라이더로 블루투스 등 장치 지연을 보정.

### 지연(프리롤) 규칙
`playbackRing` 이 목표 지연만큼 차야 재생을 시작한다. 언더런이 나면 다시 목표 지연까지 채운다 → 지연이 늘 일정하게 유지된다 (가사·음정 싱크의 전제).

## 빌드
`project.yml` → `xcodegen generate` → `CoNo.xcodeproj`. 자세한 건 [SETUP.md](SETUP.md).

### 일시정지 (즉시 멈춤)
- `DelayPipeline.setPaused(true)`: 재생 스레드는 첫 콜백만 64프레임 페이드아웃하고 링을 건드리지 않는다 (재생 위치 고정).
- 캡처 스레드는 음악 앱이 실제로 멈출 때까지 들어온 소리(꼬리)는 받고, 그 뒤 **디지털 무음만 버린다**. 재개 후에도 음악이 다시 나오거나 1.5초 유예가 끝날 때까지 무음을 버린다.
  → 재개하면 얼린 지점부터 한 샘플도 빠지지 않고 이어진다. 버린 무음은 스트림 시각에 포함되지 않으므로 음정 바·가사 싱크가 그대로다.
- 무음을 버리는 동안 `captureStreamPosition` 은 외삽하지 않는다 (가사 앵커가 미래로 튀지 않게).
- 얼린 상태에서 소리가 1초 넘게 들어오면(음악 앱에서 직접 재생) 엔진이 얼림을 푼다.
- 재생 제어: 음악 앱은 `AppleMusicScript.command`, 그 밖의 앱은 `MediaRemoteBridge`(번들의 mediaremote-adapter 를 `/usr/bin/perl` 로 실행 — "지금 재생 중" 이 캡처 중인 앱일 때만 명확한 멈춤/재생). 그것도 안 되면 `MediaKey`(⏯ 합성, 토글이라 캡처 소리로 재생 여부 확인 후).
- 끝내기 `KaraokeEngine.finish()`: 출력 얼림 → 원곡 멈춤 → 캡처가 조용해질 때까지(최대 1초) → 정리.


## 2026-10-02 — 점수 기록·공유·로컬 챌린지

`CoNo/Records`의 버전 있는 JSON을 앱과 웹이 교환한다. 곡 종료 시 `KaraokeEngine`이 `ScoreHistory`에 기록하고, `ScoreHistoryView`에서 공유·이미지·파일 내보내기를 제공한다. 웹은 `ScoreRepository`의 `JsonRepository` 구현을 사용하며 DB 호출은 하지 않는다. 개인 기록과 공개 기록을 구분한다. 상세 계약과 테스트는 [LOCAL_FEATURES.md](LOCAL_FEATURES.md).

출력 장치 변경 시 `PlaybackOutput`만 재생성하고 기존 `DelayPipeline.outputSampleRate`를 새 소스 노드 포맷으로 사용한다. 하드웨어 레이트가 달라지면 새 출력 믹서가 변환한다. 분석·채점 시계를 초기화하지 않는다. 시작 중 변경 및 재연결 실패 시에는 안전하게 정지하고 안내한다.

## 2026-10-02 — 정밀 가사·출력 복구·기록 복구

- `LyricsSources`가 TTML의 단어 시각·줄 종료를 enhanced LRC로 보존하고 `LRCParser`가 `LyricSegment`로 복원한다. `LyricsController`는 정확한 구간이 있는 줄에서 추정 정렬을 건너뛴다. 마지막 단어보다 늦은 문장 종료까지 보존한 온라인 후보 캐시는 v3다.
- `LocalLyricsStore` actor는 곡 ID·제목·가수의 SHA-256 키로 가사 JSON을 원자 저장한다. 사용자 파일이 온라인 후보보다 우선하며, 비동기 요청 세대와 곡 키로 늦은 응답을 거부한다.
- `AudioConfigurationGate`는 입력/출력 객체와 start/stop 세대를 검증한다. 교체 구간은 `DelayPipeline`의 별도 suspension으로 시계·채점을 멈추고 사용자 pause를 유지한다. 실제 그래프를 공유하는 오프라인 테스트가 레이트 변환 뒤 출력 길이/주파수를 검증한다.
- `SingingScoreSession`은 곡 시작 난이도와 누적 점수를 함께 소유한다. 설정 변경은 다음 세션부터 반영한다.
- `DiagnosticRecorder`는 사용자 요청 시 WAV와 최근 30초 통계 JSON을 새 폴더에 내보낸다. IO 콜백의 할당·락 없이 기존 버퍼를 사용한다.
- `ScoreHistory`는 읽기 오류·저장 실패·대기 결과를 구분한다. 손상된 원본과 독립적으로 대기 결과를 유효한 JSON 파일들로 내보내며 원본을 덮어쓰지 않는다.
- 웹 `FeatureVideo`는 정적 MP4/포스터/WebVTT와 텍스트 안내를 제공한다. 기존 재생 소유권과 연결하고 화면 이탈/백그라운드에서 일시정지한다.

## 2026-10-03 — 가사 작성과 저장 잠금 복구

`SRTParser`, `KRCLyrics`, `QRCLyrics`가 로컬 파일을 공통 `TimedLyrics`로 연결한다. KRC·QRC 원본은 JSON의 base64 문자열로 보존하고, 입력·압축 해제·최종 가사에 각각 상한을 적용한다. `LyricsTapSync`는 텍스트/기록 시각/재생 상태를 검증하는 순수 로직이며 `LyricsTapSyncView`가 실제 들리는 곡의 시각을 전달한다. `LyricsPublishView`는 검토한 문서만 `LRCLIBPublisher` actor에 넘긴다. 네트워크 전송과 PoW는 UI/오디오 IO에서 분리하며 테스트에는 transport를 주입한다.

`JsonRepository`의 `.write-lock-v2`는 호스트·PID·고유 토큰을 가진 완성된 폴더를 원자 설치한다. 프로세스 종료를 확인한 경우만 해당 토큰 파일을 제거하고 빈 폴더를 정리한다. 다른 작성자의 새 폴더는 비어 있지 않아 이전 작성자가 지울 수 없다. 구버전 규약과는 혼용하지 않으며 갱신 시 기존 서버를 종료한다.

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
| `CoNo/Audio/ProcessTapSession.swift` | 탭 + 비공개 애그리게이트 디바이스(메인 = 기본 출력 장치) 생성/정리 |
| `CoNo/Audio/SPSCRingBuffer.swift` | lock-free SPSC 링 버퍼 (`Synchronization.Atomic`) |
| `CoNo/Audio/DelayPipeline.swift` | IO 스레드 캡처/재생 + 워커 스레드 처리 + 프리롤 지연 |
| `CoNo/Audio/StreamProcessors.swift` | 워커 처리 단계: 패스스루 / L−R / `SeparationProcessor`(AI) |
| `CoNo/Audio/StereoResampler.swift` | 장치 레이트 ↔ 모델 레이트(44.1k) 변환 (AVAudioConverter, 워커 전용) |
| `CoNo/DSP/STFT.swift` | torch.stft/istft 호환 STFT (reflect 패딩, periodic Hann, vDSP DFT) |
| `CoNo/DSP/StreamingSeparator.swift` | 고정 길이 창 모델을 연속 스트림에 쓰는 슬라이딩 윈도우 + 크로스페이드 |
| `CoNo/Separation/MDXSeparator.swift` | UVR MDX-Net ONNX 래퍼 (ONNX Runtime + CoreML EP) |
| `CoNo/Audio/KaraokeEngine.swift` | UI 파사드 (모델 로드·벤치마크, 시작/정지, 통계 폴링) |
| `CoNoTests/DSPTests.swift` | STFT torch 일치·왕복, 슬라이딩 윈도우 정렬 테스트 |
| `CoNo/App/*` | SwiftUI 화면 |

### 스레드 모델
- **IO 스레드** (`AudioDeviceCreateIOProcIDWithBlock`, queue = nil): 탭 입력 → `captureRing`, `playbackRing` → 출력. 할당·락·로그 금지.
- **워커 스레드**: `captureRing` 에서 1024 프레임씩 읽어 `StreamProcessor` 로 처리 후 `playbackRing` 에 씀. AI 분리는 여기서 step 마다 추론(약 0.2초)하며, 그동안 캡처는 링에 계속 쌓인다.
- **메인 스레드**: 50ms 마다 `takeStats()` 로 레벨·버퍼 상태 갱신.

### AI 분리 (UVR-MDX-NET Karaoke 2)
- 모델: 44.1kHz, n_fft 5120, hop 1024, dim_f 2048, dim_t 256 → 한 창 = 261,120 샘플(약 5.9초). 출력 = 반주(코러스 포함), 보컬 = 원곡 − 반주 × 1.065.
- 전처리 순서는 python-audio-separator `MDXSeparator.run_model` 과 동일: STFT → `[L re, L im, R re, R im]` → 저주파 3빈 0 → 모델 → iSTFT.
- 슬라이딩 윈도우: `step` 마다 최근 창 전체를 분리하고, 창 끝에서 `rightContext` 앞의 `step` 구간만 사용.
  - 출력 위치 오프셋 = `rightContext` (출력 o = 입력 o − rightContext) → 가사·음정 싱크 기준
  - 최대 대기 = `rightContext + step` + 추론 시간 → 프리롤(지연)은 이보다 길어야 함
- 실측 (M1 Pro, Release): CoreML 추론 1회 약 210ms (모델 150 + STFT 60). CPU 는 약 14초로 실시간 불가.

### 지연(프리롤) 규칙
`playbackRing` 이 목표 지연만큼 차야 재생을 시작한다. 언더런이 나면 다시 목표 지연까지 채운다 → 지연이 늘 일정하게 유지된다 (가사·음정 싱크의 전제).

## 빌드
`project.yml` → `xcodegen generate` → `CoNo.xcodeproj`. 자세한 건 [SETUP.md](SETUP.md).

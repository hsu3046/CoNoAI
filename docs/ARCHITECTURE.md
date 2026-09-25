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

## 현재 구현 (PoC ①)

| 파일 | 역할 |
|---|---|
| `CoNo/Audio/CoreAudioUtils.swift` | HAL 프로퍼티 읽기 헬퍼 (AudioCap 기반) |
| `CoNo/Audio/AudioSourceCatalog.swift` | HAL 오디오 프로세스를 "책임 프로세스" 기준으로 사용자 앱에 묶어 목록화 |
| `CoNo/Audio/ProcessTapSession.swift` | 탭 + 비공개 애그리게이트 디바이스(메인 = 기본 출력 장치) 생성/정리 |
| `CoNo/Audio/SPSCRingBuffer.swift` | lock-free SPSC 링 버퍼 (`Synchronization.Atomic`) |
| `CoNo/Audio/DelayPipeline.swift` | IO 스레드 캡처/재생 + 워커 스레드 처리 + 프리롤 지연 |
| `CoNo/Audio/KaraokeEngine.swift` | UI 파사드 (시작/정지/통계 폴링) |
| `CoNo/App/*` | SwiftUI 화면 |

### 스레드 모델
- **IO 스레드** (`AudioDeviceCreateIOProcIDWithBlock`, queue = nil): 탭 입력 → `captureRing`, `playbackRing` → 출력. 할당·락·로그 금지.
- **워커 스레드**: `captureRing` 에서 1024 프레임씩 읽어 처리(`ProcessingMode`) 후 `playbackRing` 에 씀. 보컬 분리가 들어갈 자리.
- **메인 스레드**: 50ms 마다 `takeStats()` 로 레벨·버퍼 상태 갱신.

### 지연(프리롤) 규칙
`playbackRing` 이 목표 지연만큼 차야 재생을 시작한다. 언더런이 나면 다시 목표 지연까지 채운다 → 지연이 늘 일정하게 유지된다 (가사·음정 싱크의 전제).

## 빌드
`project.yml` → `xcodegen generate` → `CoNo.xcodeproj`. 자세한 건 [SETUP.md](SETUP.md).

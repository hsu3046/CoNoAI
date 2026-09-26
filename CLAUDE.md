# CoNo — 프로젝트 규칙

스트리밍 앱 소리를 가로채 홈 노래방으로 바꾸는 macOS 네이티브 앱 (Swift 6 / SwiftUI / Core Audio).
구조는 docs/ARCHITECTURE.md, 결정 근거는 docs/DECISIONS.md.

## 저작권
- 저작권자·만든 곳은 **AIB Inc. (https://www.aib.vote)** — 전역 기본값(KnowAI)이 아니다. 새 파일 머리 주석: `// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later`. 라이선스는 GPL v3.
- 내부 식별자 `space.knowai.cono`(번들 ID·UserDefaults 접두어·캐시 폴더)는 바꾸지 않는다 — 바꾸면 사용자가 허용한 권한·설정이 모두 초기화된다.

## 빌드
- `project.yml` 이 원본. `CoNo.xcodeproj` 는 `xcodegen generate` 생성물 (커밋 금지). 빌드 설정은 project.yml 에서만 바꾼다.

## Critical Gotchas
- **배포는 `scripts/release.sh` 로만** (docs/RELEASE.md): Developer ID 를 `DEVELOPMENT_TEAM` 으로 골라 서명·공증. Hardened Runtime 은 배포 빌드에서만 켜고, 새 권한이 필요하면 `Support/CoNo.entitlements` 에 추가 (없으면 배포판에서만 조용히 막힌다).
- **IO 스레드 규칙**: `DelayPipeline.renderIO` 와 그 호출 경로에서 할당·락·로그·`print`·Swift 배열 생성 금지. 버퍼는 init 에서 미리 확보.
- **피드백 루프**: 시스템 전체 탭은 CoNo 자신을 반드시 제외. 제외 실패 시 시작 거부(fail-closed)를 유지할 것.
- **탭 버퍼 위치**: 애그리게이트 입력 목록에서 탭 스트림은 서브디바이스 입력 **뒤**에 붙는다. 첫 버퍼를 탭이라고 가정하지 말 것 (지금은 탭 전용 애그리게이트지만 구성을 바꿀 때 대비).
- **탭 레이트 ≠ 출력 장치 레이트**: 탭은 앱 믹스 레이트(예: 48k)를 따른다. 출력 장치를 애그리게이트에 다시 넣지 말 것 — 레이트가 다르면 HAL 드리프트 보정이 틱을 만든다. 재생은 `PlaybackOutput`, 변환은 워커에서.
- **캡처·재생은 다른 오디오 스레드**: `renderCapture` / `renderPlayback` 는 각자 자기 상태만 만진다 (`playbackIsPrimed`·`playedFrames` 는 재생 스레드 전용).
- **장치 시작은 백그라운드**: `AudioDeviceStart` 는 오디오 권한 응답까지 블록된다.
- **Canvas 애니메이션**: TimelineView 의 `date` 를 렌더러에 넘겨야 매 틱 다시 그린다.
- **지연 일정성**: 언더런 후에도 목표 지연까지 다시 채운다. 가사·음정 싱크가 "캡처 시각 + 고정 지연"을 전제로 한다.
- **권한 거부는 에러가 아니다**: TCC 가 거부되면 탭은 무음만 준다. UI 의 무음 경고로 알린다.
- **서명**: `Support/Signing.xcconfig`(커밋, 기본 ad-hoc) 가 `Signing.local.xcconfig`(gitignore, 팀 ID) 를 `#include?` 로 덮어쓴다. 팀 ID 를 `project.yml`·문서에 쓰지 말 것 (공개 저장소). 이 Mac 은 회사 팀 인증서 수동 서명 — 로컬 파일이 없으면 조용히 ad-hoc 으로 빌드되고 빌드마다 권한을 다시 묻는다. App Service(ShazamKit 등)를 붙이면 Automatic + 프로비저닝 프로필 필요.
- **AI 모드 성능은 Release 로 잰다**: Debug 는 STFT 가 30배 느려 추론 수치가 왜곡된다.
- **CoreML EP 가 실제로 노드를 가져갔는지 확인**: 옵션이 틀려도 에러 없이 전부 CPU 로 떨어진다. `CONO_ORT_VERBOSE=1` 로 `number of nodes supported by CoreML` 확인. `RequireStaticInputShapes` 는 "0" 유지 (모델 배치 차원이 기호), `MLComputeUnits` 는 대문자 `ALL`.
- **STFT 는 torch 규칙 그대로**: reflect 패딩·periodic Hann·정규화 없음. 바꾸면 `forwardMatchesTorchDefinition` 이 잡는다 (왕복 테스트는 패딩 오류를 못 잡는다).
- **스트림 오프셋 ≠ 대기 시간**: 분리 출력의 위치 오프셋은 rightContext, step 은 대기 시간일 뿐. 싱크 계산에 섞지 말 것.
- **분리 모델 객체는 한 스레드만**: `DelayPipeline.stopWorker` 가 워커 종료를 기다린 뒤에야 같은 `MDXSeparator` 를 재사용한다.
- **ORT `tensorData()` 는 복사가 아니다**: 결과 ORTValue 가 해제되면 해제된 메모리를 읽는다 (평소엔 arena 덕에 멀쩡해 보임). 출력을 다 읽을 때까지 `withExtendedLifetime(outputValue)`.
- **시작 시도 번호(`startGeneration`)**: `start()` 의 await 뒤에는 `isCurrentStart(generation)` 로 확인. status 만 보면 "정지 → 재시작" 후 옛 시도가 살아남아 같은 분리 모델을 두 워커가 쓴다. 워커는 그 확인 **뒤에** 띄운다. 워커가 5초 안에 안 멈추면(`stopWorker() == false`) 모델을 버리고 다시 로드.
- **음정 검출 실패는 무성 프레임으로 채운다** (`PitchFrameStream.push` 는 던지지 않음): 던지면 버퍼가 안 줄어 모델 입력이 끝없이 길어지고, 프레임 번호에 빈틈이 생기면 `PitchTimeline.snapshot` 이 어긋난다.
- **ORT ObjC API 는 double 텐서를 못 읽는다** (`ORTTensorElementDataType` 에 Double 없음): 출력이 double 인 모델은 Cast(float) 변환본을 만든다 (`scripts/convert_swiftf0.py`).
- **음정 바 시간축**: 음정 프레임과 재생 위치는 둘 다 "출력 스트림 초". 여기에 rightContext 를 더하거나 빼지 말 것 (가사처럼 캡처 시각이 필요할 때만 사용).
- **자가진단 실패가 핵심 기능을 막지 않게**: 음정 검출기 실패 시에도 분리는 계속 돈다.
- **일시정지는 재생만 얼리고 캡처는 무음만 버린다** (`DelayPipeline.setPaused`): 캡처까지 바로 멈추면 음악 앱이 멈추기 전 꼬리가 사라져 재개 때 곡이 건너뛴다. 무음을 스트림에 넣으면 재개 때 그만큼 침묵이 들린다.
- **⏯ 미디어 키는 토글**: 보내기 전에 `pipeline.isSourceAudible` 로 원곡이 재생 중인지 확인 (이미 멈춘 앱에 "멈춤" 을 보내면 재생된다). 끝내기는 `finish()` — 원곡을 멈춘 뒤 정리해야 음소거가 풀릴 때 원곡이 튀어나오지 않는다.
- **자주 바뀌는 엔진 값(`stats`, 50 ms)은 작은 뷰에서만 읽는다**: 루트 뷰 body 에서 읽으면 화면 전체가 초당 20번 다시 그려진다 (`StageBackdrop`, `StatusPill`).
- **@Observable 의 didSet 에서 자기 자신에 대입 금지**: 매크로 setter 가 재진입해 무한 재귀 크래시 (키 조절 버튼 크래시). 값 보정은 변경 메서드(`changeKey(by:)`)에서.

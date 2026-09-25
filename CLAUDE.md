# CoNo — 프로젝트 규칙

스트리밍 앱 소리를 가로채 홈 노래방으로 바꾸는 macOS 네이티브 앱 (Swift 6 / SwiftUI / Core Audio).
구조는 docs/ARCHITECTURE.md, 결정 근거는 docs/DECISIONS.md.

## 빌드
- `project.yml` 이 원본. `CoNo.xcodeproj` 는 `xcodegen generate` 생성물 (커밋 금지). 빌드 설정은 project.yml 에서만 바꾼다.

## Critical Gotchas
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
- **ORT ObjC API 는 double 텐서를 못 읽는다** (`ORTTensorElementDataType` 에 Double 없음): 출력이 double 인 모델은 Cast(float) 변환본을 만든다 (`scripts/convert_swiftf0.py`).
- **음정 바 시간축**: 음정 프레임과 재생 위치는 둘 다 "출력 스트림 초". 여기에 rightContext 를 더하거나 빼지 말 것 (가사처럼 캡처 시각이 필요할 때만 사용).
- **자가진단 실패가 핵심 기능을 막지 않게**: 음정 검출기 실패 시에도 분리는 계속 돈다.
- **@Observable 의 didSet 에서 자기 자신에 대입 금지**: 매크로 setter 가 재진입해 무한 재귀 크래시 (키 조절 버튼 크래시). 값 보정은 변경 메서드(`changeKey(by:)`)에서.

# CoNo — 프로젝트 규칙

스트리밍 앱 소리를 가로채 홈 노래방으로 바꾸는 macOS 네이티브 앱 (Swift 6 / SwiftUI / Core Audio).
구조는 docs/ARCHITECTURE.md, 결정 근거는 docs/DECISIONS.md.

## 빌드
- `project.yml` 이 원본. `CoNo.xcodeproj` 는 `xcodegen generate` 생성물 (커밋 금지). 빌드 설정은 project.yml 에서만 바꾼다.

## Critical Gotchas
- **IO 스레드 규칙**: `DelayPipeline.renderIO` 와 그 호출 경로에서 할당·락·로그·`print`·Swift 배열 생성 금지. 버퍼는 init 에서 미리 확보.
- **피드백 루프**: 시스템 전체 탭은 CoNo 자신을 반드시 제외. 제외 실패 시 시작 거부(fail-closed)를 유지할 것.
- **탭 버퍼 위치**: 애그리게이트 입력 목록에서 탭 스트림은 서브디바이스 입력 **뒤**에 붙는다. 첫 버퍼를 탭이라고 가정하지 말 것 (입력 채널이 있는 오디오 인터페이스에서 깨짐).
- **지연 일정성**: 언더런 후에도 목표 지연까지 다시 채운다. 가사·음정 싱크가 "캡처 시각 + 고정 지연"을 전제로 한다.
- **권한 거부는 에러가 아니다**: TCC 가 거부되면 탭은 무음만 준다. UI 의 무음 경고로 알린다.
- **ad-hoc 서명**: 빌드마다 오디오 캡처 권한을 다시 물을 수 있다.
- **AI 모드 성능은 Release 로 잰다**: Debug 는 STFT 가 30배 느려 추론 수치가 왜곡된다.
- **CoreML EP 가 실제로 노드를 가져갔는지 확인**: 옵션이 틀려도 에러 없이 전부 CPU 로 떨어진다. `CONO_ORT_VERBOSE=1` 로 `number of nodes supported by CoreML` 확인. `RequireStaticInputShapes` 는 "0" 유지 (모델 배치 차원이 기호), `MLComputeUnits` 는 대문자 `ALL`.
- **STFT 는 torch 규칙 그대로**: reflect 패딩·periodic Hann·정규화 없음. 바꾸면 `forwardMatchesTorchDefinition` 이 잡는다 (왕복 테스트는 패딩 오류를 못 잡는다).
- **스트림 오프셋 ≠ 대기 시간**: 분리 출력의 위치 오프셋은 rightContext, step 은 대기 시간일 뿐. 싱크 계산에 섞지 말 것.
- **분리 모델 객체는 한 스레드만**: `DelayPipeline.stopWorker` 가 워커 종료를 기다린 뒤에야 같은 `MDXSeparator` 를 재사용한다.

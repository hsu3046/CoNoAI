# CoNo 프로젝트 메모리

## 2026-10-02 — 점수 공유·기록·챌린지 로컬 구현

- 사용자: macOS + 웹 모두 구현하되 DB 연결은 완료 후. 현재 Supabase 클라이언트를 호출하는 API 없음.
- 공통 JSON `{schemaVersion:1, records:[...]}`. 원본 스키마 `CoNo/Records/ScoreRecord.swift`, `web/src/lib/score-record.ts`; 양쪽 테스트가 `docs/fixtures/score-v1.json` 사용.
- Mac `Application Support/space.knowai.cono/scores.json`, 웹 `.local-data/store.json` 또는 `CONO_DATA_DIR`. 식별자 접두어를 바꾸지 않는다.
- 공유는 텍스트·PNG·JSON. 서버 기록은 기본 비공개이며 사용자가 공개한 결과만 링크·주간 순위에 노출한다. 쿠키 기반 로컬 사용자와 사용자 제공 점수이므로 운영용 인증/점수 검증은 별도.
- 파일 손상 시 무음 초기화/덮어쓰기 금지. 가져오기 중 같은 ID의 다른 내용은 전체 거부. 웹 잠금은 시간 추정으로 해제하지 않는다. 아래 v2 규약에서 종료된 동일 호스트 PID와 고유 소유자 토큰이 확인된 경우만 회수한다.
- 재생 장치 변경은 분석 파이프라인을 유지하고 재생 그래프만 교체. 기존 파이프라인 레이트를 입력 포맷으로 지정해 믹서가 새 하드웨어 레이트로 변환. 실제 장치 전환 수동 검증은 남음.
- 정밀 가사 정렬 추가 모델·간헐적 클릭 재현은 남아 있음. 실제 웹 안내 영상은 후속 구현 완료. `docs/LOCAL_FEATURES.md`에 완료 기능/테스트/한계 명시.

## 2026-10-02 — PR #10 후속 구현·리뷰 수정

- 사용자 명시로 `codex/local-feature-completion` push/PR/리뷰 및 병렬 작업 허용. PR #10, 머지/릴리즈는 요청하지 않음.
- 공통 점수 문서는 compact UTF-8 JSON 1,048,576 bytes/1,000건. 날짜에 Z/offset 필수. 요청 봉투 크기는 별도 64 KB 여유. 사본 ID는 원본 삭제 여부와 무관하게 결정해 반복 복원 중복 방지.
- Mac 읽기 오류와 대기 저장 오류는 분리. 대기 기록 export는 원본 재읽기 없이 1 MB/1,000건씩 나눔. reload로 저장 실패를 숨기지 않는다.
- TTML/enhanced LRC 원본 단어 시각·줄 종료 보존, 온라인 후보 캐시 v2. 설정에서 로컬 LRC/TTML import/replace/remove, 곡별 JSON actor 저장. 늦은 온라인 응답이 사용자 파일을 덮지 않도록 세대/곡 확인.
- 출력 교체 suspension과 출력 객체 세대 gate로 시계/채점/사용자 pause 유지, 오래된 장치 변경 콜백 무시. 난이도는 SingingScoreSession 시작값을 결과에 저장.
- 큰 렌더 버퍼의 미초기화 꼬리는 재현 후 수정. 간헐적 클릭 전체 해결로 오인 금지. 진단 저장에 diagnostics.json(최근 30초 추이/카운터/장치 레이트 등) 추가.
- TimePitch 입력 소비량은 선읽기 때문에 재생 시간 측정에 부적합. 오프라인 렌더 결과의 1초 440 Hz 톤 길이/주파수로 44.1/48/96 kHz 변환 검증.
- 실제 웹 화면으로 무음 720p 안내 영상 2편, 한국어 VTT/포스터/텍스트 제공. 생성 스크립트는 기존 FFmpeg 사용, 새 의존성 설치 없음. 원본 캡처는 Git 제외.
- 검증: macOS 빌드 + Swift Testing 103개/33 suite, 웹 단위 6개 + API 통합 + lint/build 통과. 물리 장치 전환/마이크 청취 검증은 별도.
- 추가 가사 모델은 약 365 MB omniASR CTC int8 후보·고정 해시를 문서화했으며 사용자 답변 전 다운로드하지 않는다. `docs/FORCED_ALIGNMENT_PLAN.md` 참고.

## 2026-10-03 — 가사 작성 흐름과 후속 리뷰

- 내 가사 파일에서 LRC/TTML/SRT/KRC 선택 및 드롭 지원. SRT 줄 종료 보존, KRC 원본은 base64 저장. 파서와 파일 저장의 크기/구조 한도는 모두 적용한다.
- 일반 가사 탭 싱크: Space 반복 입력은 소비만, pause/seek/곡전환/출력중단에는 기록 해제. 현재 들리는 곡 시각을 사용하고 저장 전에는 기존 가사를 바꾸지 않는다. 다른 곡을 저장하면서 현재 곡 offset을 초기화하지 않는다.
- LRCLIB 공개는 별도 검토/확인 후 사용자 버튼으로만. PoW는 120초/1억회 제한, 취소 가능, 마지막 sending await 이후에도 취소 재검사. 전송 후 응답 실패는 미확정 안내, 자동 재시도 없음. 개발 중 실제 게시 안 함(stub transport 검증).
- 텍스트 줄 구분자는 Foundation .newlines 기준. LRCParser가 해석할 수 있는 시간 태그를 일반 가사 입력에서 거부하며 저장/내보내기 오류를 try?로 숨기지 않는다.
- TTML 마지막 단어보다 늦은 p.end 보존. 옛 캐시를 무효화하려고 lyrics-extra-v3 사용.
- SingingResult는 Records로 분리. 생성된 점수만 빈 제목/UTF-16 길이를 정규화하고 긴 원본 식별자는 SHA-256 키로 보존한다. 외부 import의 검증 한도는 완화하지 않는다.
- 입력/출력 알림 공용 AudioConfigurationGate는 객체 ID+등록 세대 검사. 마이크 callback은 현재 mic identity도 확인. 가이드 보컬 채점 주의와 Bluetooth 안내를 함께 표시.
- JSON 잠금 v2: 완성된 고유 owner 파일의 폴더를 atomic rename, 같은 호스트의 종료된 PID만 token unlink→rmdir. 새 소유자의 폴더는 지우지 않는다. 구버전 서버는 모두 종료 후 갱신(혼합 규약 동시쓰기 금지). 메타데이터 없는 legacy .write-lock은 자동 회수 금지.
- 웹 8개 테스트/API/lint/build 통과. 살아 있는 실제 작성 프로세스의 잠금 보존과 SIGKILL 후 동시 쓰기 복구를 검증했다.
- 통합 macOS 빌드 + Swift Testing 147개/40 suite 통과. 물리 재생/키보드 포커스 체감·실제 LRCLIB 게시를 자동 검증한 것은 아니다.
- 사용 안내: docs/LYRICS_EDITING.md. 외부 소스 접근·권한 조건: docs/LYRICS_SOURCES.md. 실제 마이크 청취, 추가 모델 승인/성능, 운영 DB는 별도.

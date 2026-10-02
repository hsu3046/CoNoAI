# CoNo 프로젝트 메모리

## 2026-10-02 — 점수 공유·기록·챌린지 로컬 구현

- 사용자: macOS + 웹 모두 구현하되 DB 연결은 완료 후. 현재 Supabase 클라이언트를 호출하는 API 없음.
- 공통 JSON `{schemaVersion:1, records:[...]}`. 원본 스키마 `CoNo/Records/ScoreRecord.swift`, `web/src/lib/score-record.ts`; 양쪽 테스트가 `docs/fixtures/score-v1.json` 사용.
- Mac `Application Support/space.knowai.cono/scores.json`, 웹 `.local-data/store.json` 또는 `CONO_DATA_DIR`. 식별자 접두어를 바꾸지 않는다.
- 공유는 텍스트·PNG·JSON. 서버 기록은 기본 비공개이며 사용자가 공개한 결과만 링크·주간 순위에 노출한다. 쿠키 기반 로컬 사용자와 사용자 제공 점수이므로 운영용 인증/점수 검증은 별도.
- 파일 손상 시 무음 초기화/덮어쓰기 금지. 가져오기 중 같은 ID의 다른 내용은 전체 거부. 웹 잠금 디렉터리를 임의 자동 해제하지 않는다.
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

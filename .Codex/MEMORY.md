# CoNo 프로젝트 메모리

## 2026-10-03 — 전체 머지 승인·선택형 가사 모델·웹 재생 복구

- 사용자: 모든 PR 머지와 가능한 후속 수정·추가 모델 승인. DB는 마지막. 기존 PR #10은 main에 머지 완료(0a9ab04). 앞선 메모리의 모델 승인 미응답/미다운로드 상태는 이 요청으로 해소됐다.
- 고정 revision `6abf1ece20cd2308bdb7d13cd78ec1c44fa4c094`의 omniASR-CTC-300M int8 365MB를 SHA/크기 검증 후 받았다. Git 제외, 기존 ORT1.24.2 사용, 추가 패키지 설치 없음. no-replace 설치로 경합 중 새 기존 파일/폴더/symlink도 덮지 않는다. 해시·출처·실측은 docs/FORCED_ALIGNMENT_PLAN.md.
- 자동 가사 시각 학습 기본 OFF. 분리 워커의 메모리 60초 보컬 → 최대 20초/512문자 CTC → 되감기/다음 재생. 원본 단어 시각 우선. 최근 구간 일반 가사 싱크/빈 입력 받아쓰기 초안 → 검토/다시 듣기/탭 편집/LRC/명시 저장. 음성 외부 전송·파일 저장 없음.
- AlignmentCoordinator는 utility 단일 작업/ORT CPU 1스레드, 자동 작업 사이 최소 5초 또는 추론 시간 3배. native run은 중도 종료 못하므로 취소 후 완료까지 busy를 유지하며 결과/저장 권한을 철회한다. OFF/엔진 정지에 모델을 unload한다.
- LearnedWordTimingsStore는 곡·후보·원문/시각·모델 버전 키, 파일 2MiB/4,000줄, 원자 저장·손상 보존. 삭제 epoch+동기 write permit으로 늦은 이전 저장의 부활을 막는다. 창 floor/ceil로 20초+1프레임이 되던 경계는 샘플 수 상한으로 수정했다.
- 실제 자체 음성: 한국어 3.955초 forced 0.770초/textMatch 0.8571; 최대 20초 greedy 5.316초/peak footprint 1.370GB. 내부 confidence는 보정된 정확도 확률이 아니며 가창 품질 검증은 별도. 합성 경로 672/Unicode 500 독립 검토의 추가 finding은 없었다.
- 웹 점수는 서버 요청 전 `cono-pending-score-v1:<UUID>` localStorage, 성공 뒤 삭제. quota/차단은 메모리 대기+내보내기 안내, 손상/충돌 보존. 기록에서 가져오기 방식으로 재시도. StemPlayer 준비 취소·재시작·해제 세대, 숨김 탭/이탈 정지, 마이크 권한 대기/track ended 정리를 보강했다.
- SeparationMix 20ms ramp로 반주/보컬/원곡/guide 순간 전환 단차를 수정했다. 무조작 간헐적 클릭의 원인 확정은 아님. find_clicks.py는 양 채널+diagnostics 프레임 원점/분리 offset을 정렬한다. 90초 가변 chunk 리샘플러와 60초 실제 MDX 합성 입력에는 문제 재현이 없었다.
- 통합 Debug·Release 198 tests/47 suites, 웹 16 tests/API/lint/build, Python 진단 4 tests 통과. GitHub Codex review 한도는 계속 소진 상태여서 추가 원격 요청 없이 별도 로컬 리뷰로 검증했다. 실제 마이크/장치 청취와 외부 소스 권한/접근/DB는 남음.

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

## 2026-10-03 — QRC 가져오기와 최종 검증

- 로컬 QRC 바이너리/16진수 암호문/복호화된 XML·본문 지원. 전용 DES 변형·XOR는 MIT 원본 이식, THIRD_PARTY_NOTICES.md에 전문 보존. 외부 서비스 인증 키가 아니며 새 패키지 설치 없음.
- 원본 1 MiB·압축 해제 2 MiB·최종 4,000줄/줄당 500자 제한. base64 원본 보존, 새 actor에서 재로딩, 오류 시 기존 JSON 보존. 본문 `[후렴]`/`[offset:500]`/`[00:05]`는 시각 태그 뒤 공백으로 LRC 재해석 방지.
- QRC 독립 구현 105개 합성 블록 비교, 통합 macOS 168개/41 suite 통과. 웹은 마지막 변경에서 8개/API/lint/build 통과했고 이후 변경 없음.
- PR #10 원격 리뷰 8건 수정·스레드 해결. d74f7bf 재리뷰 요청은 GitHub Codex 사용량 한도로 실행되지 않아 추가 요청 중단. 이후 별도 로컬 병렬 리뷰로 가사 입력/게시 취소/KRC·SRT·QRC 경계를 검증했다. 최신 HEAD에 원격 승인이나 clean 결과가 있다고 표현하지 않는다.
- QQ 공개 검색 GET 1회 HTTP 500, Kugou 정상 TLS 실패, Musixmatch 공식 키/권한 부재로 온라인 연결 보류. 추가 365 MB 모델 승인 질문 미응답: 다운로드하지 않았다. DB 연결은 계속 후속 단계다.

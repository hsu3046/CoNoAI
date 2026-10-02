# CoNo 프로젝트 메모리

## 2026-10-02 — 점수 공유·기록·챌린지 로컬 구현

- 사용자: macOS + 웹 모두 구현하되 DB 연결은 완료 후. 현재 Supabase 클라이언트를 호출하는 API 없음.
- 공통 JSON `{schemaVersion:1, records:[...]}`. 원본 스키마 `CoNo/Records/ScoreRecord.swift`, `web/src/lib/score-record.ts`; 양쪽 테스트가 `docs/fixtures/score-v1.json` 사용.
- Mac `Application Support/space.knowai.cono/scores.json`, 웹 `.local-data/store.json` 또는 `CONO_DATA_DIR`. 식별자 접두어를 바꾸지 않는다.
- 공유는 텍스트·PNG·JSON. 서버 기록은 기본 비공개이며 사용자가 공개한 결과만 링크·주간 순위에 노출한다. 쿠키 기반 로컬 사용자와 사용자 제공 점수이므로 운영용 인증/점수 검증은 별도.
- 파일 손상 시 무음 초기화/덮어쓰기 금지. 가져오기 중 같은 ID의 다른 내용은 전체 거부. 웹 잠금 디렉터리를 임의 자동 해제하지 않는다.
- 재생 장치 변경은 분석 파이프라인을 유지하고 재생 그래프만 교체. 기존 파이프라인 레이트를 입력 포맷으로 지정해 믹서가 새 하드웨어 레이트로 변환. 실제 장치 전환 수동 검증은 남음.
- 정밀 가사 정렬 추가 모델·간헐적 클릭 재현·실제 영상은 남아 있음. `docs/LOCAL_FEATURES.md`에 완료 기능/테스트/한계 명시.

# 로컬 웹 API

© 2026 AIB Inc. (https://www.aib.vote) · GPL-3.0-or-later

DB 연결 전 파일 저장소를 사용한다. `cono-session` HttpOnly/SameSite 쿠키로 같은 로컬 서버의 개인 데이터를 구분하며 운영 로그인은 아니다. 변경 요청은 같은 출처의 JSON만 받는다. 영구 파일 저장을 보장하지 않는 Vercel 환경은 503을 반환한다. 점수 계약은 [LOCAL_FEATURES.md](LOCAL_FEATURES.md)를 참조한다.

## 개인 가사

| 요청 | 본문 | 결과 |
| --- | --- | --- |
| `GET /api/lyrics` | 없음 | 현재 쿠키 소유자의 `{records:[...]}` |
| `POST /api/lyrics` | `{action:"create",id,lyrics}` | `{record}`. 제목·가수 필수, 개인 비공개 기본값 |
| `POST /api/lyrics` | `{action:"update",id,version,lyrics}` | `{record}`. 현재 버전과 일치할 때만 수정 |
| `POST /api/lyrics` | `{action:"delete",id,version}` | `{record:null}`. 현재 소유권·버전 확인 후 삭제 |
| `POST /api/lyrics/publish` | `{action:"challenge",id,version,consent:true}` | `{challenge:{prefix,target}}`. 저장된 본인 가사를 검증한 뒤 인증 요청 |
| `POST /api/lyrics/publish` | `{action:"publish",id,version,consent:true,token}` | `{ok:true}`. 최신 저장본 버전 확인 후 명시적으로 공개 |

`lyrics`는 `{title,artist,album,duration,format,content}`다. `duration`은 초 또는 `null`, `format`은 `txt` 또는 `lrc`다. 레코드는 UUID `id`, 증가하는 `version`, ISO 날짜 `createdAt`/`updatedAt`을 추가한다. 제목·가수는 필수이며 길이는 개인 저장 시 선택, 공개 시 필수다.

한 가사는 UTF-8 1 MiB·4,000줄·줄당 500글자, 개인 보관함은 200곡·8 MiB, 서버 파일은 32 MiB 이하다. JSON 요청 봉투는 본문 이스케이프를 위한 별도 여유를 허용한다. 손상 파일은 초기화하지 않으며 잠금 안에서 읽기·검증·원자 쓰기를 수행한다. 버전 충돌은 409, 다른 소유자·없는 문서는 404, 잘못된 입력은 400이다.

LRCLIB 요청은 고정 HTTPS 주소에만 보내며 리다이렉트를 거부한다. 인증 응답은 최대 4 KiB, 요청은 20초로 제한한다. 인증 계산은 브라우저 Worker에서 최대 120초/1억회 수행하고 취소할 수 있다. 429 응답은 `Retry-After`를 반영한 대기시간을 반환하고 자동 재전송하지 않는다. 전송 뒤 네트워크 오류는 성공·실패를 단정하지 않고 결과 미확정으로 안내한다. 일반 가사는 `syncedLyrics:""`, LRC는 검토한 줄 시각과 빈 간주 cue를 보존한 공개 사본을 전송한다.

공개 후 개인 보관함 삭제는 LRCLIB 공개 사본 삭제가 아니다. 자동 테스트는 합성 가사와 주입한 전송 함수를 사용하며 실제 게시를 수행하지 않는다.

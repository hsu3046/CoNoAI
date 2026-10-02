# CoNo 소개 사이트 (`web/`)

CoNo 를 알리고, 사용법을 보여 주고, 내려받게 하고, 의견을 받는 사이트. Next.js 16 (App Router) · Tailwind 4 · 로컬 JSON.

## 구성
| 섹션 | 파일 | 내용 |
|---|---|---|
| 첫 화면 | `src/components/Hero.tsx` | 음악 앱 ▶ → 실제 노래를 원곡으로 6초(`LISTEN_MS`) → **소등과 동시에 목소리가 빠짐** → 네온 "코인 노래방" + "No!" 도장 → "집에서 나만의 노래방". 누르지 않으면 5초 뒤 소리 없이 연출만 |
| 스크롤 스토리 | `StoryScroll.tsx` | 고정 화면 4장면: 파형 → 보컬 분리 → 음정 바·가사 → 금색 선·점수·불꽃 |
| 들어 보기 | `ListenSection.tsx` · `fx/stems.ts` · `lib/songs.ts` | 자작곡 4곡 하이라이트를 원곡 ↔ 반주 ↔ 보컬로 끊김 없이 바꿔 듣기 (앱의 스위치와 같은 모양) |
| 브라우저 체험 | `TryItLive.tsx` · `fx/backing.ts` · `lib/pitch.ts` · `lib/melody.ts` | 자작곡 〈우리 집 무대〉 반주 + 마이크 음정(YIN) 채점, 끝나면 `ScoreShow` |
| 점수 연출 | `ScoreShow.tsx` · `fx/fireworks.ts` · `fx/sfx.ts` | 앱의 CelebrationView 를 옮긴 것 (드럼롤 · 불꽃 · 폭죽 · 별) |
| 소개·사용법·체험 안내·FAQ·다운로드 | `Sections.tsx` · `FeatureVideo.tsx` | 실제 화면 안내 영상·자막·텍스트 설명 |
| 기록·공유·주간 챌린지 | `ScoreLibrary.tsx` · `ChallengeBoard.tsx` · `ScoreActions.tsx` | 로컬 기록·JSON 교환·공개/해제·PNG 저장 |
| 개인 가사 보관함 | `/lyrics` · `LyricsLibrary.tsx` · `LyricsPublish.tsx` | TXT/LRC 등록·검색·편집·내보내기, 선택 LRCLIB 공개 |
| 의견 | `Feedback.tsx` → `app/api/feedback/route.ts` → 로컬 JSON | 만족도·의견·이메일(선택) |

- **노래**: `public/songs/<slug>/{mix,inst,vocal}.m4a` — 만든 이의 자작곡 (`assets/*.mp3`) 후렴 48초. **GPL 대상이 아니다 (All rights reserved)** — 다른 곳에 쓰지 말 것.
  분리는 앱과 같은 모델(UVR MDX-Net Karaoke 2)·같은 전후처리 (보컬 = 원곡 − 반주 × 1.065), 구간은 보컬이 꾸준히 큰 곳을 자동으로 고른다. 곡명·색·파형은 `lib/songs.ts`.
  세 파일은 같은 길이로 같이 인코딩해야 한다 — 세 트랙을 동시에 틀고 음량만 바꾸므로 길이가 다르면 반복 때 어긋난다.
- **페이드**: `fx/stems.ts` 의 `FADE_IN`(1.2초) · `FADE_OUT`(1.0초) 는 dB 로 부드럽게(smoothstep, 바닥 −40 dB — 음량 비율 곡선은 끝에서 뚝 끊겨 들린다), `MODE_FADE`(0.35초) 전환은 반 코사인. 재생마다 자기 페이더를 만들어 멈추는 소리와 새 소리가 겹쳐 이어진다 (곡 바꾸기·다시 틀기·위치 이동에서 뚝 끊기지 않게).
- **소리는 한 번에 한 곳**: 첫 화면 ▶ · 들어 보기 · 체험은 `claimAudio(owner)` 로 알리고, 다른 곳이 시작하면 멈춘다 (`onAudioClaim`). 화면 밖으로 나가도 멈춘다.
- **배포판 정보**: `src/lib/release.ts` (버전·다운로드 주소·크기·SHA-256). 새 DMG 를 올리면 여기만 바꾼다.
- **영상**: `public/videos/`의 1280×720 H.264 무음 안내 2편, 포스터·한국어 WebVTT·텍스트 설명. 실제 로컬 웹의 원곡/반주/보컬 전환과 테스트 점수 기록/공유/챌린지를 보여 준다. 자동 재생/사전 다운로드 없이 사용자가 재생하며, 다른 소리가 시작되거나 화면 밖·백그라운드로 가면 멈춘다. [제작·갱신 방법](../docs/VIDEO_GUIDES.md).
- **점수 연출 미리보기**: `/demo/score?score=92` (검색 노출 안 함 — 영상 촬영용)
- **공유 이미지**: `public/og.png` (첫 화면을 1200×630 으로 찍은 것)
- **아이콘**: `public/logo.png` = 배경 없는 마이크 그림 (`assets/AppIcon.icon/Assets/CoNo.png`) — 헤더·다운로드·바닥글.
  `public/app-icon-dark.png` = iOS 다크 모드 아이콘 (`ictool assets/AppIcon.icon --export-image --platform iOS --rendition Dark …`) — 앱 아이콘을 흉내 내는 자리·파비콘.
  같은 파일 이름으로 바꾸면 Next 이미지 캐시가 옛 그림을 내준다 → 이름을 바꿀 것.

## 개발
```bash
cd web
npm install
npm run dev -- --port 3100
```
추가 설정 없이 점수·의견을 `web/.local-data/store.json`에 저장한다. `CONO_DATA_DIR`로 별도 절대 경로를 지정할 수 있다. DB에는 연결하지 않는다. [전체 기능과 테스트 절차](../docs/LOCAL_FEATURES.md).

## 배포 (Vercel)
- 주소: **https://cono.aib.vote** (AIB 팀 프로젝트 `cono`, Root Directory = `web`)
- `main` 에 push 하면 자동 배포 (다른 브랜치는 Preview). 앱(Swift)만 바뀐 push 는 건너뛴다 —
  `vercel.json` 의 `ignoreCommand` 가 **마지막 성공 배포 커밋(`VERCEL_GIT_PREVIOUS_SHA`) 이후** `web/` 변경을 본다.
  `HEAD^` 와만 비교하면 여러 커밋을 한 번에 올릴 때 마지막이 앱 커밋이면 사이트 변경을 놓친다. 판단할 수 없으면(이전 배포 없음·커밋 모름) 빌드한다.
  ⚠ Vercel 은 종료 코드 0(건너뜀)·1(빌드) 외의 값을 **배포 실패**로 처리한다 — 명령은 반드시 0/1 로만 끝낼 것. 저장소를 얕게 받아 이전 커밋이 없을 수 있어 그 커밋만 fetch 해 본다.
- 배포된 사이트에 검증용 요청을 몰아 보내지 말 것 (방화벽 자동 차단) — 확인은 브라우저로.

## 점수·의견 저장 (로컬 테스트)

- `GET/POST /api/scores`: 내 기록·닉네임·가져오기·공개/해제·삭제. 소유자는 HttpOnly 쿠키로 구분한다.
- `GET /api/challenges`: 한국 시간 주간·같은 곡·출처·난이도별 개인 최고 기록.
- `/scores/<UUID>`: 공개된 점수의 공유 페이지. localhost 링크는 다른 기기에서 접근할 수 없다.
- `POST /api/feedback`: 의견을 JSON에 저장하며 외부 메일을 보내지 않는다.
- 새 점수는 서버 요청 전에 `cono-pending-score-v1:<UUID>` 키로 브라우저에 보관한다. 서버 저장이 실패해도 기록 화면에서 다시 저장·JSON/이미지 공유·삭제할 수 있다. 브라우저 저장이 차단되거나 가득 차면 메모리 대기로 유지하고 종료 전 내보내도록 안내한다. 손상된 대기 파일은 덮어쓰지 않는다.
- `npm test`: 파일/스키마·브라우저 대기 기록·비동기 재생 취소 테스트. `npm run test:api`: 실행 중인 로컬 서버의 통합 검증.
- `.local-data`는 Git/빌드에서 제외한다. 서버 프로세스를 모두 끈 뒤 원본을 백업하면 데이터 이동/복구가 가능하다.
- 잠금 v2 도입 버전으로 갱신할 때는 기존 서버를 모두 종료하고 재시작한다. 구버전과 신버전을 같은 저장 폴더에서 함께 실행하지 않는다. v2는 종료된 로컬 PID의 잠금만 자동 회수하고, 소유자 없는 구버전 `.write-lock`은 원본 백업 후 수동 확인하도록 안내한다.
- Vercel에서는 JSON 저장이 503으로 차단된다. 운영 연결은 인증·점수 검증·영구 저장소 구현 후 진행한다.

## 개인 가사 보관함 (로컬 테스트)

- `/lyrics`: 제목·가수 필수, 앨범·곡 길이 선택. 직접 입력·붙여넣기 또는 UTF-8/UTF-16 TXT·LRC 가져오기. 목록 검색, 수정, 삭제 확인, TXT/LRC 내보내기를 제공한다. 일반 가사는 TXT로 Mac 앱에 가져와 시각을 붙일 수 있다.
- `GET/POST /api/lyrics`: 기존 HttpOnly 개인 쿠키 소유권을 사용한다. `CONO_DATA_DIR/lyrics/store.json`(미설정 시 `.local-data/lyrics/store.json`)에 별도 스키마로 저장하므로 점수 저장 파일은 바꾸지 않는다. 가사 한 개는 UTF-8 1 MiB·4,000줄·줄당 500글자, 한 소유자는 200곡·8 MiB, 저장 파일 전체는 32 MiB 이하다.
- 새 레코드는 UUID와 revision(`version`) 1로 생성한다. 같은 UUID·같은 내용의 재전송은 중복 생성하지 않는다. 수정·삭제는 읽은 version이 현재와 같아야 하며 오래된 탭은 409로 거부한다. 오류가 나도 편집기는 초안을 유지하며 파일로 내보낼 수 있다.
- 기존 v2 파일 잠금을 재사용하고 read/validate/write를 잠금 안에서 처리한다. 손상 파일은 보존하고 임시 파일의 atomic rename으로 저장한다. Vercel에서는 보관함과 게시 경로 모두 저장소 연결 전 503이다. DB 연결은 없다.
- LRC 원문·단어 태그는 그대로 내보낸다. TXT와 LRCLIB 검토에는 해석한 본문을 사용한다. 양수 `[offset:500]`은 Mac 파서와 같이 0.5초 앞당긴다. LRCLIB에는 원문 단어 태그 대신 정규화한 줄 시각을 보내며 전송할 내용을 모달에서 확인할 수 있다.
- `POST /api/lyrics/publish`: 저장본의 소유권·version·명시적 동의를 확인하고 challenge 또는 publish를 수행한다. 실제 곡 길이는 공개 시 필수, 앨범은 빈 값 허용, 일반 가사는 `syncedLyrics: ""`로 보낸다. 공개본은 개인 보관함 삭제와 별개이며 앱에서 외부 공개본 삭제를 약속하지 않는다.
- 인증 계산은 Web Worker의 SHA-256으로 실행하며 120초·1억 회 제한과 취소를 제공한다. 공식 규약은 `SHA256(prefix + nonce) <= target`, 헤더는 `X-Publish-Token: prefix:nonce`다. 인증 응답 4 KiB는 앱 자체 안전 한도다. 전송 후 네트워크 실패·취소는 결과 미확정으로 표시하며 자동 재전송하지 않는다.
- 429 응답의 `Retry-After`(초 또는 HTTP 날짜)는 인증·게시 경로가 서버에서 공유한다. 대기 중에는 외부 요청을 보내지 않고 UI에 남은 시간을 표시한다. 대기가 끝나도 자동으로 게시하지 않는다. TXT 백업은 빈 행을 포함해 원문을 보존하며, 공개 LRC의 빈 시각 줄도 간주·종료 cue로 유지한다.
- [LRCLIB 공식 게시 모델/라우트](https://github.com/tranxuanthang/lrclib/blob/05ad8590f6fc4d47a2d74e70f4915273df20f63c/server/src/routes/publish_lyrics.rs), [토큰 검증식](https://github.com/tranxuanthang/lrclib/blob/05ad8590f6fc4d47a2d74e70f4915273df20f63c/server/src/utils.rs), [일반 가사 처리](https://github.com/tranxuanthang/lrclib/blob/05ad8590f6fc4d47a2d74e70f4915273df20f63c/server/src/lyricsfile.rs).
- `npm test`는 parser/소유권/revision/동시쓰기/손상 보존/PoW/전송 경계를 검증한다. LRCLIB는 주입한 가짜 transport만 사용하며 실제 POST를 보내지 않는다. `npm run test:lyrics-api`는 실행 중인 localhost 서버에 임시 개인 가사를 만들고 정리한다. 기존 점수 회귀는 `npm run test:api`로 별도 실행한다.

## 주의
- **한 화면 = 한 섹션**: `Screen`(min-h-dvh) + `SectionPager`. 마우스·트랙패드(`pointer: fine`)면 창 크기와 관계없이 **아래로만** 휠·키 한 번에 한 섹션씩 넘긴다 (위로는 자유 스크롤 — 다시 찾아보는 동작이라 걸면 답답하다). CSS `scroll-snap` 은 mandatory **든 proximity 든** 화면 높이 섹션에서 마우스 휠 한 칸(≈100px)을 원래 섹션으로 되돌려 **갇힌다** — 마우스에는 쓰지 말 것. 터치(`pointer: coarse`)만 CSS proximity.
- 화면보다 긴 섹션(스크롤 스토리)은 안쪽 자유 스크롤, 끝에서 다음 섹션으로. 새 섹션이 한 화면을 넘으면 같은 규칙이 적용된다.
- 첫 화면: 연출이 끝나기 전 스크롤하면 한 번만 붙잡고 빨리 감은 뒤 스토리로 (Hero 가 휠을 먼저 막으면 SectionPager 는 건드리지 않는다).
- `body` 는 `overflow-x: clip` — `hidden` 이면 스크롤 스토리의 sticky 가 붙지 않는다.
- 캔버스 글꼴은 `canvasFonts()` 로 — 캔버스는 CSS 변수(`var(--font-…)`)를 못 읽는다.
- 점수 연출에서 `drop-shadow` 필터·상시 혼합 모드 막을 쓰지 말 것 — 뒤의 불꽃을 네모로 가린다.
- 체험곡·가사는 CoNo 자작 (저작권 없는 것만). 드럼롤은 Freesound #569113 (CC0), 불꽃 소리는 `scripts/make_fireworks_sfx.py` 합성.

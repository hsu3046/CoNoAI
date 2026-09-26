# CoNo 소개 사이트 (`web/`)

CoNo 를 알리고, 사용법을 보여 주고, 내려받게 하고, 의견을 받는 사이트. Next.js 16 (App Router) · Tailwind 4 · Supabase.

## 구성
| 섹션 | 파일 | 내용 |
|---|---|---|
| 첫 화면 | `src/components/Hero.tsx` | 음악 앱 ▶ → 소등 → 네온 "코인 노래방" + "No!" 도장 → "집에서 나만의 노래방" |
| 스크롤 스토리 | `StoryScroll.tsx` | 고정 화면 4장면: 파형 → 보컬 분리 → 음정 바·가사 → 금색 선·점수·불꽃 |
| 브라우저 체험 | `TryItLive.tsx` · `fx/backing.ts` · `lib/pitch.ts` · `lib/melody.ts` | 자작곡 〈우리 집 무대〉 반주 + 마이크 음정(YIN) 채점, 끝나면 `ScoreShow` |
| 점수 연출 | `ScoreShow.tsx` · `fx/fireworks.ts` · `fx/sfx.ts` | 앱의 CelebrationView 를 옮긴 것 (드럼롤 · 불꽃 · 폭죽 · 별) |
| 소개·사용법·영상·챌린지·FAQ·다운로드 | `Sections.tsx` | |
| 의견 | `Feedback.tsx` → `app/api/feedback/route.ts` → Supabase `site_feedback` | |

- **배포판 정보**: `src/lib/release.ts` (버전·다운로드 주소·크기·SHA-256). 새 DMG 를 올리면 여기만 바꾼다.
- **영상**: `release.ts` 의 `videos[].src` 에 mp4 경로나 YouTube 임베드 주소를 넣으면 "촬영 중" 자리 대신 나온다.
- **점수 연출 미리보기**: `/demo/score?score=92` (검색 노출 안 함 — 영상 촬영용)
- **공유 이미지**: `public/og.png` (첫 화면을 1200×630 으로 찍은 것)

## 개발
```bash
cd web
npm install
npm run dev -- --port 3100
```
의견 저장까지 시험하려면 `.env.example` 을 `.env.local` 로 복사해 채운다 (없으면 폼이 "준비 중" 으로 답한다).

## 의견 저장 (Supabase)
1. `supabase/migrations/20260927000000_site_feedback.sql` 적용 — RLS 켜고 정책 없음 (service role 만 쓴다)
2. 환경 변수: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `FEEDBACK_IP_SALT` (서버 전용)
3. 봇 방지: 숨은 칸 · 폼 연 뒤 2.5초 · IP 해시별 10분 5건/하루 20건. IP 원문은 저장하지 않는다.

## 주의
- `body` 는 `overflow-x: clip` — `hidden` 이면 스크롤 스토리의 sticky 가 붙지 않는다.
- 캔버스 글꼴은 `canvasFonts()` 로 — 캔버스는 CSS 변수(`var(--font-…)`)를 못 읽는다.
- 점수 연출에서 `drop-shadow` 필터·상시 혼합 모드 막을 쓰지 말 것 — 뒤의 불꽃을 네모로 가린다.
- 체험곡·가사는 CoNo 자작 (저작권 없는 것만). 드럼롤은 Freesound #569113 (CC0), 불꽃 소리는 `scripts/make_fireworks_sfx.py` 합성.

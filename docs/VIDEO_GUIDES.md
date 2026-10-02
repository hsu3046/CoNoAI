# 웹 사용 안내 영상

© 2026 AIB Inc. (https://www.aib.vote) · GPL-3.0-or-later

`web/public/videos/`에 실제 로컬 웹 UI를 캡처한 1280×720 H.264 안내 두 편이 있다. 무음이며 사용자의 목소리·화면 바깥의 개인 정보·원곡 오디오는 포함하지 않는다.

- `listen-guide.mp4`: 실제 플레이어의 원곡 → 반주 → 보컬 전환 약 12초.
- `scores-guide.mp4`: 기록 → 공유 페이지 → 챌린지의 실제 화면을 각 4초 보여 주는 안내. 92점·닉네임·곡명은 `docs/fixtures/score-v1.json` 기반 테스트 데이터이며 실제 노래 성적이 아니다.
- 각 영상에 포스터 JPG, 한국어 `.ko.vtt`, `release.ts`의 글로 읽는 사용법을 제공한다.

영상은 `preload="none"`으로 클릭 후 로드한다. `FeatureVideo`가 기존 오디오 제어와 연결되어 다른 재생이 시작되거나 영상이 화면 밖/백그라운드로 이동하면 멈춘다. 오류 시 파일 링크와 텍스트 안내를 제공한다.

## 갱신

1. 로컬 테스트 서버에서 1280×720 뷰포트로 실제 화면을 캡처한다. 화면에 개인 기록이 없는지 확인한다.
2. 원곡→반주→보컬 약 4초씩의 브라우저 screencast JPEG와 시각/파일명 JSON(`frames.json`, clip=`listen-master`)을 준비한다.
3. 점수 화면 3장을 `scores-records.jpg`, `scores-share.jpg`, `scores-challenge.jpg`로 준비한다.
4. 기존 설치된 FFmpeg로 `python3 scripts/build_web_guides.py output/video-capture`를 실행한다. 스크립트는 촬영하지 않고 전달받은 프레임만 인코딩한다.
5. 화면 내용이 바뀌면 WebVTT와 `release.ts` 텍스트를 함께 수정하고, 실제 브라우저에서 재생·키보드·모바일 레이아웃을 확인한다.

원본 캡처는 로컬 `output/video-capture/`에 보관하고 완성 파일만 버전 관리한다. 실시간 상호작용을 보고 싶으면 각 영상 아래의 실제 기능 링크를 사용한다.

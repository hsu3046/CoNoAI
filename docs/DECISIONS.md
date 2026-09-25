# 결정 기록

## 2026-09-25 — macOS 네이티브 (Swift) 로 시작
- 후보: A) macOS 네이티브 / B) Tauri + Python 추론 / C) Chrome 확장
- 선택: **A**. Core Audio process tap(macOS 14.2+)이 앱별 캡처와 원본 음소거(`mutedWhenTapped`)를 공식 API 로 제공. iOS 는 원천 불가, Android 는 Spotify/Apple Music 이 캡처를 막아둔다.

## 2026-09-25 — 애그리게이트 한 개에서 입출력을 같이 처리
- 탭과 기본 출력 장치를 한 애그리게이트로 묶고 한 IOProc 에서 입력(탭)을 받고 출력에 씀.
- 이유: 별도 출력 엔진을 쓰면 클럭이 두 개가 되어 드리프트 보정이 필요. 한 IOProc 이면 같은 클럭.
- 한계: 시작 후 기본 출력 장치를 바꿔도 따라가지 않는다 (재시작 필요).

## 2026-09-25 — 지연 버퍼(프리롤) 방식
- 초저지연 분리 모델 대신 N초 늦게 재생해서 그 시간을 분석에 쓴다. 원본은 음소거되므로 사용자는 지연을 느끼지 않는다.
- 부수 효과: 앞으로 부를 음정을 N초 미리 보여줄 수 있다.
- 비용: 곡 시작 시 N초 무음, 탐색·건너뛰기 반응이 N초 늦음.

## 2026-09-25 — 앱 그룹핑에 responsible pid (private SPI) 사용
- 브라우저·Electron 앱은 헬퍼 프로세스가 소리를 낸다 (Safari → `com.apple.WebKit.GPU`).
- `responsibility_get_pid_responsible_for_pid` 를 dlsym 으로 찾고, 없으면 번들 ID 접두어 매칭으로 폴백.
- App Store 배포 시 재검토 필요.

## 2026-09-25 — 시스템 전체 캡처는 자기 제외 실패 시 거부 (fail-closed)
- CoNo 출력이 다시 탭으로 들어가면 무한 에코. 자기 프로세스 오브젝트를 못 찾으면 시작하지 않는다.

## 2026-09-25 — 로컬 PoC 는 ad-hoc 서명
- 팀 ID 없이 바로 빌드 가능. 대신 빌드마다 서명이 바뀌어 오디오 캡처 권한을 다시 물을 수 있다.

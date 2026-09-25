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

## 2026-09-25 — 검증: Apple Music (FairPlay) 캡처 동작 확인
- Apple Music 앱을 process tap 으로 캡처 + 원본 음소거 + 지연 재생까지 정상 동작 (사용자 실측).
- 타당성 조사의 1순위 리스크("DRM 재생 소리가 캡처되는가")가 Apple Music 에서는 해소됨. 멜론·YouTube Music(Chrome) 은 미검증.

## 2026-09-25 — 보컬 분리: ONNX Runtime + UVR MDX-Net Karaoke 2
- 후보: A) ONNX Runtime + MDX-Net / B) Demucs → CoreML 변환 / C) Python 보조 프로세스
- 선택: **A**. 네이티브 단일 앱, 모델 교체 쉬움, Karaoke 모델이 코러스를 반주에 남겨 노래방 느낌에 가깝다.
- 모델 파일은 커밋하지 않고 `scripts/fetch-models.sh` 로 받는다 (UVR 해시로 설정값 검증). 가중치 라이선스 미명시 → 배포 전 확인 필요.

## 2026-09-25 — 슬라이딩 윈도우 스트리밍 (step / rightContext / fade)
- 모델 창(5.9초)이 고정이라 매 step 마다 창 전체를 다시 분리하고 뒤쪽 일부만 쓴다. 연산은 늘지만 지연을 초 단위로 조절 가능.
- 기본값 step 1.0초, rightContext 1.0초, fade 2048 샘플. 권장 프리롤 = rightContext + step + 추론×1.5 + 0.5초.

## 2026-09-25 — CoreML: RequireStaticInputShapes = "0"
- UVR 모델은 배치 차원이 기호(`batch_size`)라 "1" 이면 CoreML 이 178개 노드를 전부 거부 → 전부 CPU(약 14초/창).
- ObjC API 에 free dimension override 가 없어 동적 형태 허용으로 해결 → 전 노드 CoreML, 약 150ms/창.
- MLComputeUnits 값은 대문자 `ALL` (헤더 주석의 "All" 은 거부됨).

## 2026-09-25 — 검증: AI 분리 실사용 품질 확인
- Apple Music 곡으로 실시간 분리 재생 — 사용자 평가 "거의 완벽하게 분리". 기본값(step 1.0초, rightContext 1.0초, CoreML 자동)으로 충분.

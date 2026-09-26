# 개발 환경

## 요구 사항
- macOS 15+ (process tap 은 14.2+, `Synchronization` 모듈 때문에 15)
- Xcode 26+ (Swift 6)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## 모델 받기 (AI 분리용, 약 53MB)
```bash
./scripts/fetch-models.sh
```
`Models/` 에 받고 UVR 해시로 검증한다. 빌드할 때 앱 번들에 들어간다 (없어도 빌드는 되지만 AI 모드가 실패).

## 빌드·실행
**AI 분리를 쓸 때는 Release 빌드**로 실행한다. Debug 빌드는 Swift 최적화가 꺼져 STFT 가 창당 약 2초(Release 60ms) 걸려 실시간이 안 된다.
```bash
xcodegen generate
xcodebuild -project CoNo.xcodeproj -scheme CoNo -configuration Release -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Release/CoNo.app
```
Debug 빌드:
```bash
xcodegen generate
xcodebuild -project CoNo.xcodeproj -scheme CoNo -configuration Debug -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/CoNo.app
```
Xcode 로 열어도 된다: `open CoNo.xcodeproj`. `CoNo.xcodeproj` 는 생성물이라 커밋하지 않는다 — 설정은 `project.yml` 에서 바꾼다.

배포용(서명·공증 DMG) 빌드는 [RELEASE.md](RELEASE.md).

## 권한
설정 › 일반 › 권한에 세 가지가 쓰임과 함께 나오고, "열기" 로 해당 시스템 설정 화면이 열린다.

| 권한 | 쓰임 | 필요 |
|---|---|---|
| 화면 및 시스템 오디오 녹음 | 연결된 앱의 소리 캡처. 없으면 무음만 들어온다 (진단 탭 모니터에 "입력이 계속 무음" 경고) | 필수 |
| 자동화 › 음악 | Apple Music 곡 정보·재생 위치, 재생·일시정지·이동 | 음악 앱을 쓸 때 |
| 손쉬운 사용 | 다른 앱을 멈추는 예비 수단(⏯ 미디어 키 합성) | 보통 불필요 |

- 음악 앱이 아닌 앱(브라우저 등)의 곡 정보·재생 제어는 macOS "지금 재생 중" 을 번들의 mediaremote-adapter(`ThirdParty/`)로 읽는다. 별도 권한이 필요 없다 (애플 서명 `/usr/bin/perl` 로 실행).
- 첫 캡처 시작 때 "시스템 오디오 녹음" 권한 창이 뜬다. 거부했거나 창이 안 떴는데 입력 레벨이 0 이면: 시스템 설정 › 개인정보 보호 및 보안 › 화면 및 시스템 오디오 녹음 › CoNo 허용.
- 서명 설정은 `Support/Signing.xcconfig` 에 있다. 기본은 ad-hoc(`-`) 이라 누구나 바로 빌드되지만, 빌드마다 서명이 바뀌어 권한을 다시 묻는다.
- 개발 인증서로 서명하려면 (권한이 "앱 ID + 인증서" 로 기억돼 다시 빌드해도 묻지 않는다):
  ```bash
  cp Support/Signing.local.xcconfig.example Support/Signing.local.xcconfig   # git 에 올라가지 않는다
  # DEVELOPMENT_TEAM 을 자기 팀 ID 로 바꾼다 (키체인에 그 팀의 Apple Development 인증서 필요)
  xcodegen generate
  ```
  확인: `codesign -dv build/DerivedData/Build/Products/Release/CoNo.app` 의 `TeamIdentifier` 가 팀 ID 면 성공, `Signature=adhoc` 이면 로컬 파일이 안 읽힌 것.
- Apple Music 의 가사·재생 제어는 **자동화 권한**(CoNo → 음악)이 필요하다. 거부했다면 시스템 설정 › 개인정보 보호 및 보안 › 자동화 › CoNo › 음악.
- 어댑터 동작 확인 (앱 번들 안의 것으로):
  ```bash
  APP=build/DerivedData/Build/Products/Release/CoNo.app
  /usr/bin/perl "$APP/Contents/Resources/mediaremote-adapter.pl" "$PWD/$APP/Contents/Frameworks/MediaRemoteAdapter.framework" get --no-artwork
  ```

## 테스트
```bash
xcodebuild test -project CoNo.xcodeproj -scheme CoNo -derivedDataPath build/DerivedData -only-testing:CoNoTests
```

## ONNX Runtime 진단 로그
CoreML 이 몇 개 노드를 가져갔는지 등:
```bash
CONO_ORT_VERBOSE=1 build/DerivedData/Build/Products/Release/CoNo.app/Contents/MacOS/CoNo 2>&1 | grep -E "GetCapability|placed on"
```

## 로그
```bash
log stream --predicate 'subsystem == "space.knowai.cono"' --level debug
```

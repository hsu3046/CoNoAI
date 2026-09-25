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

## 오디오 캡처 권한
- 첫 캡처 시작 때 "시스템 오디오 녹음" 권한 창이 뜬다.
- 거부했거나 창이 안 떴는데 입력 레벨이 0 이면: 시스템 설정 › 개인정보 보호 및 보안 › 화면 및 시스템 오디오 녹음 › CoNo 허용.
- 앱은 **AIB Inc. 개발 인증서**(팀 `9BF5ZBVYYF`)로 서명한다 → 권한이 "앱 ID + 인증서" 로 기억돼 다시 빌드해도 묻지 않는다 (서명 방식을 바꾼 직후 한 번만 다시 묻는다).
  다른 Mac 에서 빌드하려면 그 Mac 키체인에 같은 팀 인증서가 있어야 한다. 없으면 `project.yml` 의 `CODE_SIGN_IDENTITY` 를 `"-"`(ad-hoc)로 바꾸면 빌드는 되지만 빌드마다 권한을 다시 묻는다.
- 가사 기능은 **자동화 권한**(CoNo → 음악)이 필요하다. 거부했다면 시스템 설정 › 개인정보 보호 및 보안 › 자동화 › CoNo › 음악.

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

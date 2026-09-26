# 배포 (홈페이지 · Developer ID)

CoNo 는 Mac App Store 가 아니라 **Developer ID 서명 + Apple 공증** 한 DMG 로 배포한다.

## 왜 App Store 가 아닌가
| 심사 규정 | CoNo 에서 걸리는 것 |
|---|---|
| 2.4.5(i) 샌드박스 필수 | 샌드박스 안에서는 프로세스 탭이 불안정하고, `/usr/bin/perl` 실행(Now Playing)과 미디어 키 보내기가 막힌다 |
| 2.5.1 공개 API 만 | Now Playing 읽기·제어가 비공개 MediaRemote 를 쓴다 (mediaremote-adapter) |
| 5.2.2 · 5.2.3 제3자 서비스 약관 | Apple Music 비공식 API, NetEase API, 스트리밍 앱 소리 캡처 |

핵심 기능을 빼야 통과하므로 직접 배포한다. 샌드박스는 쓰지 않는다.

## 한 번만 준비
1. **Developer ID Application 인증서** (AIB Inc. 팀) — Xcode › Settings › Accounts › 팀 › Manage Certificates › + › Developer ID Application. 팀의 Account Holder 만 만들 수 있다.
2. **팀 설정** — `Support/Signing.local.xcconfig` 에 `DEVELOPMENT_TEAM` (커밋하지 않는다, [SETUP.md](SETUP.md)).
3. **공증 자격 증명** — App Store Connect 팀 API 키(Developer 이상) 또는 앱 암호를 키체인 프로필로 저장:
   ```bash
   xcrun notarytool store-credentials cono-notary --key ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>
   ```
   키·ID 는 저장소에 두지 않는다. 스크립트는 프로필 이름(`cono-notary`)만 쓴다.
4. **모델** — `./scripts/fetch-models.sh`

## 배포 빌드
```bash
scripts/release.sh
```
하는 일:
1. 준비물 확인 — 키체인에 여러 팀의 Developer ID 가 있어도 `DEVELOPMENT_TEAM` 의 것만 전체 이름으로 고른다
2. Release 빌드 — Developer ID 서명, **Hardened Runtime**, 보안 타임스탬프, 디버거 권한(get-task-allow) 제외
3. 서명 검증 (앱·안에 든 프레임워크)
4. 앱 공증 → staple (DMG 밖으로 옮겨도 오프라인에서 열린다)
5. DMG (앱 + `/Applications` 바로가기) → 서명 → 공증 → staple
6. 게이트키퍼 판정 (`spctl`) — 다른 Mac 에서 내려받아 여는 것과 같은 검사
7. `build/release/CoNo-<버전>.dmg` 와 `.sha256`

실패하면 공증 로그를 그대로 출력하고 멈춘다.

## 권한 (Hardened Runtime)
`Support/CoNo.entitlements`:
- `com.apple.security.automation.apple-events` — 음악 앱 곡 정보·재생 위치, 브라우저 탭 제목
- `com.apple.security.device.audio-input` — 프로세스 탭을 애그리게이트 장치의 입력으로 읽는다

Hardened Runtime 은 배포 빌드에서만 켠다 (`project.yml` 은 `NO`, 스크립트가 켠다). 개발·오픈소스 빌드(ad-hoc 포함)는 그대로 둔다.

## 버전 올리기
`project.yml` 의 `MARKETING_VERSION`(표시 버전)과 `CURRENT_PROJECT_VERSION`(빌드 번호)을 올리고 커밋한 뒤 스크립트를 돌린다.

## 배포 전 확인 (서명·공증된 앱으로)
서명이 바뀌면 macOS 가 권한을 새로 묻는다. 새 사용자 입장에서 한 번씩:
- [ ] 오디오 캡처 권한 요청 → 허용 후 반주가 나온다
- [ ] 음악 앱 곡 정보·가사 (자동화 › 음악)
- [ ] Chrome/YouTube 곡 정보·멈춤·되감기 (Now Playing), 광고 알아채기 (자동화 › 브라우저)
- [ ] AI 반주 (모델 로드)

## 이후
- 자동 업데이트: 없음. 필요하면 Sparkle(MIT) 추가.

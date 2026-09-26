#!/bin/bash
# CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
#
# 홈페이지 배포용 DMG 만들기: Release 빌드 → Developer ID 서명(Hardened Runtime) → 앱 공증·staple
# → DMG → DMG 서명·공증·staple → 게이트키퍼 확인. 결과: build/release/CoNo-<버전>.dmg (+ .sha256)
#
# 준비 (docs/RELEASE.md):
#   - Support/Signing.local.xcconfig 에 DEVELOPMENT_TEAM
#   - 그 팀의 "Developer ID Application" 인증서가 키체인에
#   - 공증 프로필: xcrun notarytool store-credentials cono-notary (API 키 또는 앱 암호)
#   - Models/ 에 분리 모델 (scripts/fetch-models.sh)
#
# 사용: scripts/release.sh            (공증 프로필 이름을 바꾸려면 NOTARY_PROFILE=이름)

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

NOTARY_PROFILE=${NOTARY_PROFILE:-cono-notary}
LOCAL_SIGNING=Support/Signing.local.xcconfig
OUT=build/release

fail() { echo "✗ $*" >&2; exit 1; }
step() { echo; echo "▸ $*"; }

# MARK: - 준비물 확인

step "준비물 확인"
command -v xcodegen >/dev/null || fail "xcodegen 이 없습니다 (brew install xcodegen)"

TEAM=$(sed -nE 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([A-Z0-9]{10}).*/\1/p' "$LOCAL_SIGNING" 2>/dev/null | head -1)
[ -n "$TEAM" ] || fail "$LOCAL_SIGNING 에 DEVELOPMENT_TEAM 이 없습니다"

# 키체인에 여러 팀의 Developer ID 가 있을 수 있다 → 이 팀 것만, 전체 이름으로 고른다
IDENTITY=$(security find-identity -v -p codesigning \
    | sed -nE "s/.*\"(Developer ID Application: .* \($TEAM\))\".*/\1/p" | head -1)
[ -n "$IDENTITY" ] || fail "이 팀의 Developer ID Application 인증서가 키체인에 없습니다"
echo "  서명: ${IDENTITY% (*}"

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || fail "공증 프로필 '$NOTARY_PROFILE' 을 쓸 수 없습니다 (xcrun notarytool store-credentials $NOTARY_PROFILE)"
echo "  공증: $NOTARY_PROFILE"

compgen -G "Models/*.onnx" >/dev/null || fail "Models/ 에 분리 모델이 없습니다 (scripts/fetch-models.sh)"

VERSION=$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*([0-9][0-9.]*).*/\1/p' project.yml | head -1)
[ -n "$VERSION" ] || fail "project.yml 에서 MARKETING_VERSION 을 못 읽었습니다"
echo "  버전: $VERSION"

APP="$OUT/DerivedData/Build/Products/Release/CoNo.app"
DMG="$OUT/CoNo-$VERSION.dmg"

# MARK: - 공증 (제출 → 기다림 → 실패면 로그)

notarize() {
    local file=$1 result status id
    result=$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format plist)
    status=$(plutil -extract status raw -o - - <<<"$result" 2>/dev/null || echo "?")
    id=$(plutil -extract id raw -o - - <<<"$result" 2>/dev/null || echo "")
    echo "  결과: $status"
    if [ "$status" != "Accepted" ]; then
        [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" || true
        fail "공증 실패: $(basename "$file")"
    fi
}

# MARK: - 빌드·서명

step "빌드 (Release · Developer ID · Hardened Runtime)"
rm -rf "$OUT"
mkdir -p "$OUT"
xcodegen generate --quiet
# CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO: 디버거 권한(get-task-allow)이 들어가면 공증이 거절한다
xcodebuild -project CoNo.xcodeproj -scheme CoNo -configuration Release \
    -destination "generic/platform=macOS" -derivedDataPath "$OUT/DerivedData" -clonedSourcePackagesDirPath build/SourcePackages \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
    ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    build -quiet

step "서명 확인"
codesign --verify --deep --strict "$APP" || fail "서명 검증 실패"
entitlements=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)
[[ "$entitlements" == *get-task-allow* ]] && fail "get-task-allow 가 들어 있습니다"
details=$(codesign -dvv "$APP" 2>&1)
[[ "$details" == *"(runtime)"* ]] || fail "Hardened Runtime 이 꺼져 있습니다"
[[ "$details" == *"Timestamp="* ]] || fail "보안 타임스탬프가 없습니다"
for framework in "$APP"/Contents/Frameworks/*.framework; do
    codesign --verify --strict "$framework" || fail "서명 검증 실패: $(basename "$framework")"
done
echo "  앱·프레임워크 서명 정상"

# MARK: - 앱 공증 (DMG 없이 앱을 옮겨도 오프라인에서 열리게 앱에도 staple)

step "앱 공증"
ditto -c -k --keepParent "$APP" "$OUT/CoNo-app.zip"
notarize "$OUT/CoNo-app.zip"
xcrun stapler staple -q "$APP"
rm "$OUT/CoNo-app.zip"

# MARK: - DMG

step "DMG 만들기"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/CoNo.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "CoNo $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGE"
codesign --sign "$IDENTITY" --timestamp "$DMG"

step "DMG 공증"
notarize "$DMG"
xcrun stapler staple -q "$DMG"

# MARK: - 게이트키퍼 확인 (다른 Mac 에서 내려받아 여는 것과 같은 판정)

step "게이트키퍼 확인"
spctl --assess --type execute "$APP" || fail "게이트키퍼가 앱을 거부합니다"
spctl --assess --type open --context context:primary-signature "$DMG" || fail "게이트키퍼가 DMG 를 거부합니다"
xcrun stapler validate -q "$DMG" || fail "DMG 에 공증 티켓이 없습니다"
echo "  앱·DMG 모두 통과 (Notarized Developer ID)"

(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo
echo "✓ 완료: $DMG ($(du -h "$DMG" | cut -f1))"
echo "  SHA-256: $(cut -d' ' -f1 "$DMG.sha256")"

#!/bin/zsh
# Builds Release Ferry (universal). Signs with the first "Apple Development" identity in
# your Keychain when there is one — a stable signature means macOS keeps folder
# permissions and Keychain access across rebuilds — otherwise ad-hoc. Nothing personal
# is stored in the repo.
# Usage: scripts/build-release.sh [--install | --dist]
#   --install  copies the build to /Applications
#   --dist     ad-hoc signs (a certificate would put its owner's name in the download) and
#              writes Ferry-<version>-macOS.zip plus its SHA-256 to $BUILD_ROOT/dist
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_ROOT="${FERRY_BUILD_ROOT:-$HOME/Library/Caches/FerryBuild}"
MODE="${1:-}"
SIGNING=()
IDENTITY=$(security find-identity -p codesigning -v 2>/dev/null | awk '/Apple Development/ {print $2; exit}')
if [[ "$MODE" == "--dist" ]]; then
  # Stripping drops the symbol table's debug map, which holds this Mac's source paths.
  SIGNING=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=
    DEPLOYMENT_POSTPROCESSING=YES STRIP_INSTALLED_PRODUCT=YES)
  echo "▸ Distribution build — stripped, signing ad-hoc"
elif [[ -n "$IDENTITY" ]]; then
  TEAM=$(security find-certificate -c "Apple Development" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU=\([A-Z0-9]*\).*/\1/p')
  SIGNING=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$IDENTITY" "DEVELOPMENT_TEAM=$TEAM" PROVISIONING_PROFILE_SPECIFIER=)
  echo "▸ Signing with Apple Development identity (team $TEAM)"
else
  echo "▸ No Apple Development identity found — signing ad-hoc"
fi
xcodebuild -scheme Ferry -configuration Release -destination "generic/platform=macOS" \
  -derivedDataPath "$BUILD_ROOT/DerivedData" build -quiet "${SIGNING[@]}"
APP="$BUILD_ROOT/DerivedData/Build/Products/Release/Ferry.app"
codesign --verify --deep --strict "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Authority|Signature=|TeamIdentifier|Identifier=" | head -3
echo "▸ Built $APP ($(lipo -archs "$APP/Contents/MacOS/Ferry"))"

if [[ "$MODE" == "--install" ]]; then
  osascript -e 'tell application "Ferry" to quit' 2>/dev/null || true
  rm -rf /Applications/Ferry.app
  ditto "$APP" /Applications/Ferry.app
  echo "▸ Installed /Applications/Ferry.app"
elif [[ "$MODE" == "--dist" ]]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
  DIST="$BUILD_ROOT/dist"
  ZIP="$DIST/Ferry-$VERSION-macOS.zip"
  for arch in arm64 x86_64; do
    lipo "$APP/Contents/MacOS/Ferry" -verify_arch "$arch" || { echo "✘ No $arch slice" >&2; exit 1; }
  done
  rm -rf "$DIST" && mkdir -p "$DIST"
  # Stage a copy without extended attributes, re-verify, and zip it the way Finder does.
  ditto --norsrc --noextattr "$APP" "$DIST/stage/Ferry.app"
  xattr -cr "$DIST/stage/Ferry.app"
  codesign --verify --deep --strict "$DIST/stage/Ferry.app"
  if LC_ALL=C grep -rlaF "$HOME" "$DIST/stage/Ferry.app"; then
    echo "✘ The files above contain this Mac's home path" >&2; exit 1
  fi
  ditto -c -k --norsrc --noextattr --keepParent "$DIST/stage/Ferry.app" "$ZIP"
  rm -rf "$DIST/stage"
  (cd "$DIST" && shasum -a 256 "${ZIP:t}" > "${ZIP:t}.sha256")

  # What a downloader gets: unzip in a temp dir and check the signature holds.
  CHECK=$(mktemp -d -t ferry-dist-check)
  ditto -x -k "$ZIP" "$CHECK"
  codesign --verify --deep --strict --verbose=1 "$CHECK/Ferry.app"
  spctl -a -vv "$CHECK/Ferry.app" 2>&1 | sed 's/^/  spctl: /' || true   # "rejected" is expected: not notarized
  rm -rf "$CHECK"
  echo "▸ $ZIP"
  cat "$ZIP.sha256"
fi

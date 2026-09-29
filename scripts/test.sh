#!/bin/zsh
# Builds and tests everything from the CLI: the FerryKit engine package, then the app.
# Build output lives outside the repo: iCloud-synced folders add xattrs that break codesign.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_ROOT="${FERRY_BUILD_ROOT:-$HOME/Library/Caches/FerryBuild}"

echo "▸ FerryKit (swift test)"
swift test --package-path Packages/FerryKit --scratch-path "$BUILD_ROOT/FerryKit" "$@"

echo "▸ Ferry app (xcodebuild test)"
xcodebuild -scheme Ferry -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "$BUILD_ROOT/DerivedData" test 2>&1 \
  | grep -E "✔ Test run|✘|error:|\*\* TEST (SUCCEEDED|FAILED)"

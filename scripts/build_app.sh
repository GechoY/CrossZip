#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CROSSZIP_ROOT="$PWD"
bash scripts/build_native.sh
swift build -c release
CROSSZIP_BIN="$(swift build -c release --show-bin-path)"
mkdir -p "$CROSSZIP_ROOT/dist"
CROSSZIP_STAGE="$(mktemp -d "$CROSSZIP_ROOT/dist/.bundle.XXXXXX")"
trap 'rm -rf "$CROSSZIP_STAGE"' EXIT
CROSSZIP_APP="$CROSSZIP_STAGE/CrossZip.app"
mkdir -p "$CROSSZIP_APP/Contents/MacOS" "$CROSSZIP_APP/Contents/Resources" "$CROSSZIP_APP/Contents/Frameworks"
cp "$CROSSZIP_BIN/CrossZip" "$CROSSZIP_APP/Contents/MacOS/CrossZip"
cp "$CROSSZIP_ROOT/Resources/Info.plist" "$CROSSZIP_APP/Contents/Info.plist"
cp "$CROSSZIP_ROOT/THIRD_PARTY_NOTICES.md" "$CROSSZIP_APP/Contents/Resources/"
cp "$CROSSZIP_ROOT/LICENSE" "$CROSSZIP_APP/Contents/Resources/"
cp -R "$CROSSZIP_ROOT/Vendor/Native/licenses" "$CROSSZIP_APP/Contents/Resources/Native-Licenses"
swift "$CROSSZIP_ROOT/scripts/make_icon.swift" "$CROSSZIP_STAGE/CrossZip.iconset"
iconutil -c icns "$CROSSZIP_STAGE/CrossZip.iconset" -o "$CROSSZIP_APP/Contents/Resources/CrossZip.icns"
xcrun swift-stdlib-tool --copy --platform macosx --scan-executable "$CROSSZIP_APP/Contents/MacOS/CrossZip" --destination "$CROSSZIP_APP/Contents/Frameworks"
codesign --force --sign - --timestamp=none "$CROSSZIP_APP"
codesign --verify --strict --verbose=2 "$CROSSZIP_APP"
plutil -lint "$CROSSZIP_APP/Contents/Info.plist"
rm -rf "$CROSSZIP_ROOT/dist/CrossZip.app"
mv "$CROSSZIP_APP" "$CROSSZIP_ROOT/dist/CrossZip.app"
cp "$CROSSZIP_BIN/crosszip-cli" "$CROSSZIP_ROOT/dist/crosszip-cli"
printf '应用已生成：%s/dist/CrossZip.app\n' "$CROSSZIP_ROOT"

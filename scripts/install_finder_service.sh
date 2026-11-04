#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CROSSZIP_ROOT="$PWD"
CROSSZIP_SOURCE="$CROSSZIP_ROOT/dist/CrossZip.app"
CROSSZIP_APPLICATIONS="$HOME/Applications"
CROSSZIP_DESTINATION="$CROSSZIP_APPLICATIONS/CrossZip.app"
if [ ! -d "$CROSSZIP_SOURCE" ]; then
    printf '请先运行 bash scripts/build_app.sh。\n' >&2
    exit 1
fi
codesign --verify --strict "$CROSSZIP_SOURCE"
mkdir -p "$CROSSZIP_APPLICATIONS"
if [ -e "$CROSSZIP_DESTINATION" ] || [ -L "$CROSSZIP_DESTINATION" ]; then
    if [ -L "$CROSSZIP_DESTINATION" ] || [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$CROSSZIP_DESTINATION/Contents/Info.plist")" != 'local.echo.CrossZip' ]; then
        printf '目标位置已有其他内容，未覆盖：%s\n' "$CROSSZIP_DESTINATION" >&2
        exit 1
    fi
fi
CROSSZIP_STAGE="$(mktemp -d "$CROSSZIP_APPLICATIONS/.crosszip-install.XXXXXX")"
trap 'rm -rf "$CROSSZIP_STAGE"' EXIT
ditto "$CROSSZIP_SOURCE" "$CROSSZIP_STAGE/CrossZip.app"
codesign --verify --strict "$CROSSZIP_STAGE/CrossZip.app"
rm -rf "$CROSSZIP_DESTINATION"
mv "$CROSSZIP_STAGE/CrossZip.app" "$CROSSZIP_DESTINATION"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$CROSSZIP_DESTINATION"
# Start the installed service-capable build without terminating an older running task.
open -n "$CROSSZIP_DESTINATION" --args --register-finder-service
printf '已安装：%s\n右键文件或文件夹 → 服务 → 使用 CrossZip 压缩。\n' "$CROSSZIP_DESTINATION"

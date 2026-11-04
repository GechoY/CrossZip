#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CROSSZIP_ROOT="$PWD"
bash scripts/build_app.sh
CROSSZIP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
CROSSZIP_NAME="CrossZip-$CROSSZIP_VERSION-macos-arm64"
CROSSZIP_RELEASE="$CROSSZIP_ROOT/dist/releases/v$CROSSZIP_VERSION"
CROSSZIP_STAGE="$(mktemp -d "$CROSSZIP_ROOT/dist/.release.XXXXXX")"
trap 'rm -rf "$CROSSZIP_STAGE"' EXIT
mkdir -p "$CROSSZIP_STAGE/image" "$CROSSZIP_RELEASE"
ditto "$CROSSZIP_ROOT/dist/CrossZip.app" "$CROSSZIP_STAGE/image/CrossZip.app"
codesign --verify --strict "$CROSSZIP_STAGE/image/CrossZip.app"
ln -s /Applications "$CROSSZIP_STAGE/image/Applications"
cp LICENSE "$CROSSZIP_STAGE/image/LICENSE.txt"
cat > "$CROSSZIP_STAGE/image/请先阅读.txt" <<'EOF'
CrossZip — Apple 芯片 Mac，macOS 14 或更新版本。

将 CrossZip.app 拖到 Applications，然后打开。
本版本采用 ad-hoc 本地签名，尚未经过 Apple 公证。
若 macOS 阻止打开，请先核对 GitHub 发布页的 SHA-256，再按 Apple 说明操作：
https://support.apple.com/zh-cn/102445
系统设置 → 隐私与安全性 → 允许打开此应用。无需关闭 Gatekeeper。

Finder 选中文件 → 服务 → 使用 CrossZip 压缩。系统自带压缩工具继续保留。
所有文件在本机处理。Windows 非法名称会提示，仍按原名保存。
完整 Windows 资源管理器双向实机验收仍待完成。
EOF
ditto -c -k --keepParent --norsrc --noextattr "$CROSSZIP_STAGE/image/CrossZip.app" "$CROSSZIP_STAGE/$CROSSZIP_NAME.zip"
hdiutil create -quiet -volname CrossZip -srcfolder "$CROSSZIP_STAGE/image" -format UDZO "$CROSSZIP_STAGE/$CROSSZIP_NAME.dmg"
mv -f "$CROSSZIP_STAGE/$CROSSZIP_NAME.zip" "$CROSSZIP_STAGE/$CROSSZIP_NAME.dmg" "$CROSSZIP_RELEASE/"
(
    cd "$CROSSZIP_RELEASE"
    shasum -a 256 "$CROSSZIP_NAME.dmg" "$CROSSZIP_NAME.zip" > SHA256SUMS
    shasum -a 256 -c SHA256SUMS
)
printf '发布文件：%s\n' "$CROSSZIP_RELEASE"

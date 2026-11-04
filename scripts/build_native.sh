#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CROSSZIP_ROOT="$PWD"
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
    printf 'CrossZip 当前仅支持 Apple 芯片 Mac（arm64，macOS 14 或更新版本）。\n' >&2
    exit 1
fi
CROSSZIP_NATIVE="$CROSSZIP_ROOT/Vendor/Native"
CROSSZIP_VERSIONS='libarchive 3.8.11; xz 5.8.4; arm64; macOS 14'
if [ -f "$CROSSZIP_NATIVE/lib/libarchive.a" ] && [ -f "$CROSSZIP_NATIVE/lib/liblzma.a" ] &&
   [ -f "$CROSSZIP_NATIVE/include/archive.h" ] && [ -f "$CROSSZIP_NATIVE/include/archive_entry.h" ] &&
   [ -f "$CROSSZIP_NATIVE/licenses/libarchive-COPYING.txt" ] &&
   [ -f "$CROSSZIP_NATIVE/licenses/xz-COPYING.txt" ] && [ -f "$CROSSZIP_NATIVE/licenses/xz-COPYING.0BSD.txt" ] &&
   [ -f "$CROSSZIP_NATIVE/versions.txt" ] &&
   [ "$(cat "$CROSSZIP_NATIVE/versions.txt")" = "$CROSSZIP_VERSIONS" ]; then
    exit 0
fi
(cd Vendor/Sources && shasum -a 256 -c SHA256SUMS)
mkdir -p "$CROSSZIP_ROOT/test-artifacts"
# Autotools/libtool do not consistently handle spaces in installation prefixes.
CROSSZIP_WORK="$(mktemp -d /tmp/crosszip-native.XXXXXX)"
trap 'CROSSZIP_STATUS=$?; if [ "$CROSSZIP_STATUS" -ne 0 ] && [ -f "$CROSSZIP_WORK/libarchive-3.8.11/config.log" ]; then cp "$CROSSZIP_WORK/libarchive-3.8.11/config.log" "$CROSSZIP_ROOT/test-artifacts/native-config.log"; fi; rm -rf "$CROSSZIP_WORK"' EXIT
CROSSZIP_PREFIX="$CROSSZIP_WORK/prefix"
CROSSZIP_SDK="$(xcrun --show-sdk-path)"
export CC="$(xcrun --find clang)"
export MACOSX_DEPLOYMENT_TARGET=14.0
export CFLAGS="-O2 -arch arm64 -isysroot $CROSSZIP_SDK"
export CPPFLAGS="-isysroot $CROSSZIP_SDK"
export LDFLAGS="-arch arm64 -isysroot $CROSSZIP_SDK"
export SOURCE_DATE_EPOCH=1793318400
tar -xf "$CROSSZIP_ROOT/Vendor/Sources/xz-5.8.4.tar.xz" -C "$CROSSZIP_WORK"
cd "$CROSSZIP_WORK/xz-5.8.4"
./configure --prefix="$CROSSZIP_PREFIX" --disable-shared --enable-static --disable-nls \
    --disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo --disable-scripts --disable-doc
make -j8
make install
tar -xf "$CROSSZIP_ROOT/Vendor/Sources/libarchive-3.8.11.tar.xz" -C "$CROSSZIP_WORK"
cd "$CROSSZIP_WORK/libarchive-3.8.11"
export CPPFLAGS="-isysroot $CROSSZIP_SDK -I$CROSSZIP_PREFIX/include"
export LDFLAGS="$LDFLAGS -L$CROSSZIP_PREFIX/lib"
./configure --prefix="$CROSSZIP_PREFIX" --disable-shared --enable-static \
    --disable-bsdtar --disable-bsdcpio --disable-bsdcat --disable-bsdunzip \
    --disable-acl --disable-xattr --without-openssl --without-xml2 --without-expat \
    --without-bsdxml --without-libb2 --without-lz4 --without-zstd --without-md \
    --without-libiconv-prefix
make -j8
make install
mkdir -p "$CROSSZIP_NATIVE/lib" "$CROSSZIP_NATIVE/include" "$CROSSZIP_NATIVE/licenses"
cp "$CROSSZIP_PREFIX/lib/libarchive.a" "$CROSSZIP_PREFIX/lib/liblzma.a" "$CROSSZIP_NATIVE/lib/"
cp "$CROSSZIP_PREFIX/include/archive.h" "$CROSSZIP_PREFIX/include/archive_entry.h" "$CROSSZIP_NATIVE/include/"
cp "$CROSSZIP_WORK/libarchive-3.8.11/COPYING" "$CROSSZIP_NATIVE/licenses/libarchive-COPYING.txt"
cp "$CROSSZIP_WORK/xz-5.8.4/COPYING" "$CROSSZIP_NATIVE/licenses/xz-COPYING.txt"
cp "$CROSSZIP_WORK/xz-5.8.4/COPYING.0BSD" "$CROSSZIP_NATIVE/licenses/xz-COPYING.0BSD.txt"
printf '%s\n' "$CROSSZIP_VERSIONS" > "$CROSSZIP_NATIVE/versions.txt"

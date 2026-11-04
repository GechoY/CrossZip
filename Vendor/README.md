# Native archive dependencies

Official source releases are retained in `Sources/` with pinned `SHA256SUMS`:

- [libarchive 3.8.11](https://github.com/libarchive/libarchive/releases/tag/v3.8.11)
- [XZ Utils / liblzma 5.8.4](https://github.com/tukaani-project/xz/releases/tag/v5.8.4)

Run `bash scripts/build_native.sh` from the project. It verifies the source
archives, configures and builds in a temporary path without spaces, then copies
the static libraries, public headers and licenses into `Native/`. The existing
build is reused when its version stamp matches. To rebuild, remove only
`Vendor/Native/versions.txt` and run the script again.

Target: arm64, macOS 14.0 minimum. Xcode's SDK supplies public zlib, bzip2 and
iconv libraries. XZ command-line programs and all libarchive command-line
programs are disabled; ACL/xattr support and optional external libraries are
disabled. The Swift backend registers only built-in filters, with no runtime
command fallbacks. The application links the two `.a` libraries directly.

The application includes the license texts from `Native/licenses/`; test-only
fixtures and their resource bundle are excluded from the packaged app.

# Third-party components

CrossZip 1.5 uses libarchive for all archive creation. ZIP reading uses CrossZip's
independent bounded directory reader and public macOS zlib for Stored/Deflate
payloads. The zlib license is available at https://zlib.net/zlib_license.html .

ZIPFoundation 0.9.20 (MIT), pinned to commit
`22787ffb59de99e5dc1fbfe80b19c97a904ad48d`, is retained only as an independent
fixture dependency in the test target. It is not linked into the app or shipped
as a runtime resource. Its unmodified source and LICENSE remain available in
SwiftPM checkouts: https://github.com/weichsel/ZIPFoundation/tree/0.9.20 .

Archive creation and other-format reading use **libarchive 3.8.11** with **liblzma from XZ Utils 5.8.4**,
statically linked into the application. Sources are pinned official release
tarballs in `Vendor/Sources`, verified by `SHA256SUMS`, and built with
`scripts/build_native.sh`. No external archive executables are launched at runtime.

- libarchive: https://github.com/libarchive/libarchive/releases/tag/v3.8.11
  Its upstream `COPYING` file, containing BSD and component notices, is included
  as `Native-Licenses/libarchive-COPYING.txt`.
- XZ Utils/liblzma: https://github.com/tukaani-project/xz/releases/tag/v5.8.4
  Upstream `COPYING` and `COPYING.0BSD` are included as
  `Native-Licenses/xz-COPYING.txt` and `xz-COPYING.0BSD.txt`. Only the static
  liblzma library is included, not XZ command-line programs.
- zlib, bzip2 and iconv are public macOS system libraries. No Homebrew libraries
  or private system libarchive are linked.

Test-only libarchive fixtures retain their upstream provenance and license in
`Tests/CrossZipCoreTests/Fixtures/README.txt` and `libarchive-COPYING.txt`.
They are not included in the application bundle.

The UI uses Apple's SwiftUI/AppKit and SF Symbols; these are provided by macOS.

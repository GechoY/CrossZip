Test fixture provenance

The following files were UU-decoded, without changing their archive bytes, from
the libarchive 3.8.11 official source release, libarchive/test/<filename>.uu:
  test_read_format_rar.rar
  test_read_format_rar5_solid.rar
  test_read_format_rar_encryption_header.rar
  test_read_format_cab_1.cab
  test_read_format_cpio_filename_utf8_jp.cpio

Source: https://github.com/libarchive/libarchive/tree/v3.8.11/libarchive/test
Release: Vendor/Sources/libarchive-3.8.11.tar.xz (SHA256SUMS pinned).
The upstream license is copied beside this file as libarchive-COPYING.txt.

corrupt-symlink-crc.7z was independently generated on this Mac with system
bsdtar: a symbolic link named "link" with target "checksum-target", stored with
--format=7zip --options=7zip:compression=store. One byte of the raw link target
was then flipped without changing its CRC or directory. This regression fixture
checks the per-header CRC diagnostic even when libarchive returns ARCHIVE_OK.

Fixtures are test resources only and are excluded from the application bundle.

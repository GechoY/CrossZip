#!/usr/bin/env python3
"""Independent format/byte checks using Python codecs, system tar/ar and real RAR fixtures."""
import argparse
import bz2
import gzip
import hashlib
import io
import json
import lzma
import os
from pathlib import Path
import random
import struct
import subprocess
import tarfile
import tempfile
import time
import zipfile
import zlib

parser = argparse.ArgumentParser()
parser.add_argument('--cli', required=True, type=Path)
parser.add_argument('--report', type=Path, default=Path('test-artifacts/multiformat-interop-report.json'))
args = parser.parse_args()
cli = str(args.cli.resolve())
project = Path(__file__).resolve().parent.parent
checks = []


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def call(*arguments, expected=(0,)):
    result = subprocess.run([cli, *map(str, arguments), '--quiet'], capture_output=True, text=True)
    require(result.returncode in expected, f'{arguments}: exit {result.returncode}\n{result.stderr}')
    return json.loads(result.stdout) if result.stdout.strip() else None


def check(name, callback):
    started = time.monotonic()
    callback()
    checks.append({'name': name, 'status': 'passed', 'seconds': round(time.monotonic() - started, 3)})
    print('PASS', name, flush=True)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def lzip_compress(data):
    # Independent single-member LZIP v1: LZMA1 payload + CRC/size trailer.
    encoded = lzma.compress(data, format=lzma.FORMAT_RAW,
                            filters=[{'id': lzma.FILTER_LZMA1, 'dict_size': 65536, 'lc': 3, 'lp': 0, 'pb': 2}])
    return b'LZIP\x01\x10' + encoded + struct.pack('<IQQ', zlib.crc32(data), len(data), 6 + len(encoded) + 20)


def unix_compress(data):
    # Apple's compress emits no bytes for empty stdin. Use the valid empty .Z
    # header exercised by libarchive's own test_read_filter_compress_empty2.
    if not data:
        return b'\x1f\x9d\x10'
    return subprocess.run(['/usr/bin/compress', '-fc'], input=data, capture_output=True, check=True).stdout


def inventory(folder):
    result = {}
    def visit(current, prefix=''):
        for child in current.iterdir():
            name = prefix + child.name
            if child.is_symlink():
                result[name] = ('symlink', os.readlink(child))
            elif child.is_dir():
                result[name] = ('directory',)
                visit(child, name + '/')
            else:
                result[name] = ('file', digest(child.read_bytes()))
    visit(folder)
    return result


with tempfile.TemporaryDirectory(prefix='CrossZip-Multi-Interop-') as temporary:
    root = Path(temporary)
    source = root / '原样资料'
    (source / '空目录').mkdir(parents=True)
    (source / '深层').mkdir()
    rng = random.Random(20261103)
    payloads = {'中文🙂.txt': '文字内容\r\n'.encode(), '.gitignore': b'build/\n',
                '.DS_Store': b'\0\0\0\1Bud1' + bytes(32), '._ordinary': b'ordinary data',
                'CON.txt': b'', 'a?.txt': b'question', 'a\\b.bin': bytes(range(256)),
                'line\nfeed': b'new line filename',
                '深层/random.bin': bytes(rng.getrandbits(8) for _ in range(131073)),
                '深层/repeated.bin': b'compression pattern ' * 8192}
    for name, data in payloads.items():
        (source / name).write_bytes(data)
    (source / 'link').symlink_to('中文🙂.txt')
    (source / 'broken').symlink_to('missing')
    expected = {'原样资料': ('directory',), **{'原样资料/' + name: value for name, value in inventory(source).items()}}
    archives = {}

    def native_outputs():
        for fmt in ('zip', '7z', 'tar', 'tar.gz', 'tar.bz2', 'tar.xz'):
            archive = root / ('output.' + fmt)
            call('pack', '--format', fmt, '--output', archive, source)
            archives[fmt] = archive
            call('verify', archive)
            if fmt == 'zip':
                with zipfile.ZipFile(archive) as reader:
                    require(reader.testzip() is None, 'Python rejected ZIP CRC')
                    for name, data in payloads.items():
                        require(reader.read('原样资料/' + name) == data, name)
            elif fmt.startswith('tar'):
                with tarfile.open(archive, 'r:*') as reader:
                    for name, data in payloads.items():
                        require(reader.extractfile('原样资料/' + name).read() == data, fmt + ':' + name)
                    require(reader.getmember('原样资料/link').linkname == '中文🙂.txt', 'TAR link changed')
            else:
                # System libarchive 3.7.4 is a separate build from bundled 3.8.11.
                independent = root / 'system-7z'
                independent.mkdir()
                subprocess.run(['/usr/bin/tar', '--options=tar:!mac-ext', '-xf', str(archive), '-C', str(independent)],
                               check=True, capture_output=True, env={**os.environ, 'COPYFILE_DISABLE': '1', 'LANG': 'en_US.UTF-8'})
                require(inventory(independent) == expected, 'System 7z extraction differs')
            output = Path(call('extract', archive, '--to', root)['outputPath'])
            require(inventory(output) == expected, fmt + ' round trip changed names/bytes/structure')
        require(inventory(source) == {name.removeprefix('原样资料/'): value for name, value in expected.items() if name != '原样资料'},
                'Original inputs changed')
    check('Six write formats: independent readers + exact names, SHA-256, hidden files, links and empty folders', native_outputs)

    def levels_and_store():
        for fmt in ('7z', 'tar.gz', 'tar.bz2', 'tar.xz'):
            for level in (1, 9):
                archive = root / f'level-{level}.{fmt}'
                call('pack', '--format', fmt, '--level', level, '--output', archive, source)
                call('verify', archive)
        stored = root / 'stored.zip'
        call('pack', '--output', stored, '--store', source)
        with zipfile.ZipFile(stored) as reader:
            require(all(entry.compress_type == 0 for entry in reader.infolist()), 'ZIP Store is not actually Stored')
    check('Real compression levels and ZIP Stored mode', levels_and_store)

    def selected_files():
        for fmt, archive in archives.items():
            output = Path(call('extract', archive, '--to', root, '--include', '原样资料/中文🙂.txt')['outputPath'])
            require(inventory(output) == {'原样资料': ('directory',), '原样资料/中文🙂.txt': ('file', digest(payloads['中文🙂.txt']))}, fmt)
    check('Selective extraction retains only requested files and required parents in all six formats', selected_files)

    def external_tar_and_streams():
        for mode in ('w', 'w:gz', 'w:bz2', 'w:xz'):
            archive = root / ('external-' + mode.replace(':', '-') + '.tar')
            with tarfile.open(archive, mode) as writer:
                writer.add(source, arcname='原样资料')
            output = Path(call('extract', archive, '--to', root)['outputPath'])
            require(inventory(output) == expected, mode)
        tar_bytes = io.BytesIO()
        with tarfile.open(fileobj=tar_bytes, mode='w') as writer:
            entry = tarfile.TarInfo('inside.txt'); entry.size = 3
            writer.addfile(entry, io.BytesIO(b'tar'))
        for suffix, compress in (('gz', gzip.compress), ('bz2', bz2.compress), ('xz', lzma.compress),
                                ('lzma', lambda data: lzma.compress(data, format=lzma.FORMAT_ALONE)),
                                ('lz', lzip_compress), ('Z', unix_compress)):
            for number, payload in enumerate((b'', b'unchanged bytes\r\n' * 1024,
                                              bytes(4096) + b'keep zero blocks', tar_bytes.getvalue())):
                archive = root / (f'payload-{number}.bin.' + suffix)
                archive.write_bytes(compress(payload))
                output = Path(call('extract', archive, '--to', root)['outputPath'])
                require((output / archive.stem).read_bytes() == payload, suffix)
        joined = root / 'joined.lz'; joined.write_bytes(lzip_compress(b'first') + lzip_compress(b'second'))
        output = Path(call('extract', joined, '--to', root)['outputPath'])
        require((output / 'joined').read_bytes() == b'firstsecond', 'LZIP members were truncated')
    check('Independent TAR and six compressed streams: empty files, leading zero blocks, one-layer payloads and LZIP members', external_tar_and_streams)

    def gzip_corruption():
        valid = gzip.compress(b'CRC must be checked')
        for offset in (len(valid) - 8, len(valid) - 4):
            invalid = bytearray(valid); invalid[offset] ^= 1
            archive = root / f'bad-crc-{offset}.gz'; archive.write_bytes(invalid)
            call('verify', archive, expected=(1,))
        joined = root / 'joined.txt.gz'; joined.write_bytes(gzip.compress(b'first') + gzip.compress(b'second'))
        output = Path(call('extract', joined, '--to', root)['outputPath'])
        require((output / 'joined.txt').read_bytes() == b'firstsecond', 'GZIP concatenation was truncated')
    check('Independent GZIP CRC/ISIZE failures and concatenated members', gzip_corruption)

    def rar_cab_cpio():
        fixtures = project / 'Tests/CrossZipCoreTests/Fixtures'
        for name in ('test_read_format_rar.rar', 'test_read_format_rar5_solid.rar',
                     'test_read_format_cab_1.cab', 'test_read_format_cpio_filename_utf8_jp.cpio'):
            archive = fixtures / name
            output = Path(call('extract', archive, '--to', root)['outputPath'])
            independent = root / ('system-' + name)
            independent.mkdir()
            subprocess.run(['/usr/bin/tar', '-xf', str(archive), '-C', str(independent)], check=True, capture_output=True,
                           env={**os.environ, 'COPYFILE_DISABLE': '1', 'LANG': 'en_US.UTF-8'})
            require(inventory(output) == inventory(independent), name)
    check('Upstream real RAR/RAR5 solid/CAB/CPIO fixtures compared with system extraction', rar_cab_cpio)

    def iso_ar():
        folder = root / 'iso-source'; folder.mkdir(); (folder / '文件.txt').write_bytes(b'ISO original')
        archive = root / 'image.iso'
        subprocess.run(['/usr/bin/tar', '--format=iso9660', '-cf', str(archive), '-C', str(folder), '.'], check=True,
                       capture_output=True, env={**os.environ, 'COPYFILE_DISABLE': '1', 'LANG': 'en_US.UTF-8'})
        output = Path(call('extract', archive, '--to', root)['outputPath'])
        require((output / '文件.txt').read_bytes() == b'ISO original', 'ISO changed file')
        item = root / 'ar-source.txt'; item.write_bytes(b'AR original')
        archive = root / 'archive.ar'
        # Apple ranlib (the implicit `s`) discards non-Mach-O members. Disable
        # indexing so this fixture actually contains the ordinary input file.
        subprocess.run(['/usr/bin/ar', 'rcS', str(archive), str(item)], check=True, capture_output=True)
        output = Path(call('extract', archive, '--to', root)['outputPath'])
        require((output / item.name).read_bytes() == b'AR original', 'AR changed file')
    check('Real system-created ISO and AR images', iso_ar)

    def failures():
        for fmt, archive in archives.items():
            if fmt == 'zip':
                continue
            damaged = root / ('damaged.' + fmt)
            data = archive.read_bytes()
            damaged.write_bytes(data[:-(512 if fmt == 'tar' else 12)])
            call('extract', damaged, '--to', root, expected=(1,))
        bad = root / 'unsafe.tar'
        with tarfile.open(bad, 'w') as writer:
            entry = tarfile.TarInfo('../outside'); entry.size = 3
            writer.addfile(entry, io.BytesIO(b'bad'))
        call('extract', bad, '--to', root, expected=(1,))
        call('verify', project / 'Tests/CrossZipCoreTests/Fixtures/corrupt-symlink-crc.7z', expected=(1,))
        call('inspect', project / 'Tests/CrossZipCoreTests/Fixtures/test_read_format_rar_encryption_header.rar', expected=(1,))
        require(not list(root.glob('.crosszip-*')), 'Temporary output was not cleaned')
        require(not (root.parent / 'outside').exists(), 'Path traversal wrote outside output')
    check('Truncation, unsafe paths, ignored upstream symlink CRC and unsupported encryption fail cleanly', failures)

report = {'status': 'passed', 'checks': checks, 'windows_explorer': 'pending real Windows verification'}
args.report.parent.mkdir(parents=True, exist_ok=True)
args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(f'{len(checks)} groups passed. Report: {args.report}')

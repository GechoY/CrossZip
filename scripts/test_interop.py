#!/usr/bin/env python3
"""Independent zipfile/zlib/ditto/unzip checks. Python is a development dependency only."""
import argparse
import hashlib
import io
import json
import os
import pathlib
import random
import struct
import subprocess
import tempfile
import time
import zipfile
import zlib
from datetime import datetime
from zoneinfo import ZoneInfo

if not __debug__:
    raise SystemExit("交叉验证依赖断言，请关闭 Python -O / PYTHONOPTIMIZE 优化模式后运行。")

parser = argparse.ArgumentParser()
parser.add_argument("--cli", required=True, type=pathlib.Path)
parser.add_argument("--report", type=pathlib.Path, default=pathlib.Path("test-artifacts/interop-report.json"))
args = parser.parse_args()
binary = str(args.cli.resolve())
checks = []


def run_cli(*arguments, expected=0, env=None):
    result = subprocess.run([binary, *map(str, arguments), "--quiet"], capture_output=True, text=True, env=env)
    if result.returncode != expected:
        raise AssertionError(f"{arguments}: exit {result.returncode}, expected {expected}\n{result.stderr}")
    return json.loads(result.stdout) if result.stdout.strip() else None


def check(name, callback):
    started = time.monotonic()
    callback()
    checks.append({"name": name, "status": "passed", "seconds": round(time.monotonic() - started, 3)})
    print("PASS", name, flush=True)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def simple_zip(path, name, payload, *, flags=0x800, method=0, extra=b"", declared_size=None, bad_crc=False):
    compressed = payload
    if method == 8:
        compressor = zlib.compressobj(wbits=-15)
        compressed = compressor.compress(payload) + compressor.flush()
    crc = zlib.crc32(payload) ^ (0xFFFFFFFF if bad_crc else 0)
    size = len(payload) if declared_size is None else declared_size
    local = struct.pack("<I5H3I2H", 0x04034B50, 20, flags, method, 0, 0x5821,
                        crc, len(compressed), size, len(name), len(extra)) + name + extra + compressed
    central = struct.pack("<I6H3I5H2I", 0x02014B50, 0x314, 20, flags, method, 0, 0x5821,
                          crc, len(compressed), size, len(name), len(extra), 0, 0, 0, 0x81A40000, 0) + name + extra
    end = struct.pack("<I4H2IH", 0x06054B50, 0, 0, 1, 1, len(central), len(local), 0)
    path.write_bytes(local + central + end)


with tempfile.TemporaryDirectory(prefix="CrossZip 互通测试 ") as temporary:
    root = pathlib.Path(temporary)
    source = root / "跨系统资料"
    source.mkdir()
    (source / "空文件夹").mkdir()
    (source / "data").mkdir()
    rng = random.Random(20261103)
    payloads = {
        "中文 文件.txt": "路径损耗与无线信道\n".encode(),
        "emoji 🧪.txt": "中文 English 🙂\n".encode(),
        "data/random.bin": bytes(rng.getrandbits(8) for _ in range(524289)),
        "zero": b"", ".gitignore": b".build/\n", "._ordinary": b"ordinary, keep this file",
        ".DS_Store": b"\x00\x00\x00\x01Bud1" + bytes(32),
    }
    for name, data in payloads.items():
        (source / name).write_bytes(data)
    archive = root / "CrossZip.zip"

    def native_output():
        packed = run_cli("pack", "--output", archive, source)
        assert packed["fileCount"] == len(payloads)
        with zipfile.ZipFile(archive) as reader:
            assert reader.testzip() is None
            names = set(reader.namelist())
            assert all(member.flag_bits & 0x800 for member in reader.infolist())
            assert "跨系统资料/空文件夹/" in names
            assert "跨系统资料/.DS_Store" in names
            assert not any(name.startswith("__MACOSX/") for name in names)
            for name, data in payloads.items():
                assert digest(reader.read("跨系统资料/" + name)) == digest(data)
        subprocess.run(["/usr/bin/unzip", "-tqq", str(archive)], check=True, capture_output=True)
        run_cli("verify", archive)
        extracted = pathlib.Path(run_cli("extract", archive, "--to", root)["outputPath"])
        for name, data in payloads.items():
            assert digest((extracted / source.name / name).read_bytes()) == digest(data)
    check("CrossZip output: Python zipfile + system unzip + SHA-256 round trip", native_output)

    def exact_names_and_bytes():
        folder = root / "原样保存"
        folder.mkdir()
        names = ["CON.txt", "report?.txt", "a*b.bin", "a\\b.txt", "a:b.txt", "tail.", "tail ", "line\nfeed.txt"]
        expected = {}
        for index, name in enumerate(names):
            data = bytes(range(256)) + f"原文不替换 {index}\r\n".encode()
            (folder / name).write_bytes(data)
            expected[folder.name + "/" + name] = data
        # The hierarchy exceeds the old Windows budget and must remain intact.
        deep = folder.joinpath(*("original-level-" + str(i) for i in range(20)))
        deep.mkdir(parents=True)
        (deep / "empty").mkdir()
        original = deep / "数据.txt"
        original.write_bytes("深层原文".encode())
        expected[original.relative_to(root).as_posix()] = original.read_bytes()
        archive = root / "原样保存.zip"
        scan = run_cli("scan", folder)
        assert scan["canProceed"] and scan["issues"]
        assert all(issue["severity"] == "warning" for issue in scan["issues"])
        run_cli("pack", "--output", archive, folder)
        with zipfile.ZipFile(archive) as reader:
            assert reader.testzip() is None
            assert {entry.filename for entry in reader.infolist() if not entry.is_dir()} == set(expected)
            for path, data in expected.items():
                assert reader.read(path) == data
        output = pathlib.Path(run_cli("extract", archive, "--to", root)["outputPath"])
        for path, data in expected.items():
            assert digest((output / path).read_bytes()) == digest(data)
            assert digest((root / path).read_bytes()) == digest(data)
        assert (output / deep.relative_to(root) / "empty").is_dir()
    check("Original special names, deep hierarchy and all file bytes are unchanged", exact_names_and_bytes)

    def exact_symlinks():
        folder = root / "links"
        folder.mkdir()
        targets = {"external": "../../outside.txt", "broken": "missing.txt", "cycle": "."}
        for name, target in targets.items():
            (folder / name).symlink_to(target)
        archive = root / "links.zip"
        run_cli("pack", "--output", archive, folder)
        with zipfile.ZipFile(archive) as reader:
            assert len(reader.infolist()) == len(targets) + 1
            for name, target in targets.items():
                entry = reader.getinfo(folder.name + "/" + name)
                assert entry.external_attr >> 16 & 0o170000 == 0o120000
                assert reader.read(entry) == os.fsencode(target)
        output = pathlib.Path(run_cli("extract", archive, "--to", root)["outputPath"])
        for name, target in targets.items():
            assert os.readlink(output / folder.name / name) == target
            assert os.readlink(folder / name) == target
    check("Symlink types and target bytes are retained without dereferencing", exact_symlinks)

    def external_zipfiles():
        for level in (0, 1, 9):
            incoming = root / f"python-{level}.zip"
            expected = {}
            with zipfile.ZipFile(incoming, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=level) as writer:
                writer.writestr("空目录/", b"")
                for size in (0, 1, 65535, 65536, 65537, 1048576):
                    data = ((b"compressible payload" * 5000) + bytes(rng.getrandbits(8) for _ in range(70000)))
                    data = (data * (size // len(data) + 1))[:size]
                    name = f"中文🙂/{size}.bin"
                    writer.writestr(name, data)
                    expected[name] = data
            output = pathlib.Path(run_cli("extract", incoming, "--to", root)["outputPath"])
            for name, data in expected.items():
                assert digest((output / name).read_bytes()) == digest(data)
        incoming = root / "stored.zip"
        with zipfile.ZipFile(incoming, "w", compression=zipfile.ZIP_STORED) as writer:
            writer.writestr("stored.txt", b"123456789")
        assert run_cli("verify", incoming)["members"][0]["crc32"] == 0xCBF43926
    check("External Stored/Deflate streams at levels 0/1/9 and chunk boundaries", external_zipfiles)

    def descriptors():
        class NonSeekable(io.BytesIO):
            def seekable(self):
                return False
            def seek(self, *unused):
                raise io.UnsupportedOperation("non-seekable fixture")
        for force64 in (False, True):
            stream = NonSeekable()
            with zipfile.ZipFile(stream, "w", compression=zipfile.ZIP_DEFLATED) as writer:
                with writer.open("中文.txt", "w", force_zip64=force64) as entry:
                    entry.write(b"descriptor" * 7000)
            path = root / f"descriptor-{force64}.zip"
            path.write_bytes(stream.getvalue())
            run_cli("verify", path)
    check("Independent streaming data descriptors, including forced ZIP64 local headers", descriptors)

    def mac_system():
        system_source = root / "系统打包"
        system_source.mkdir()
        (system_source / "中文.txt").write_bytes("来自系统 ditto".encode())
        (system_source / "empty").mkdir()
        path = root / "ditto.zip"
        subprocess.run(["/usr/bin/ditto", "-c", "-k", "--norsrc", "--noextattr", "--keepParent", str(system_source), str(path)], check=True)
        preview = run_cli("inspect", path)
        assert any(item["severity"] == "warning" for item in preview["issues"])
        output = pathlib.Path(run_cli("extract", path, "--to", root, "--encoding", "utf8")["outputPath"])
        assert (output / "系统打包/中文.txt").read_bytes() == "来自系统 ditto".encode()
        assert (output / "系统打包/empty").is_dir()
    check("macOS ditto unflagged UTF-8 is warned; explicit UTF-8 restores original names", mac_system)

    def encodings():
        path = root / "legacy.zip"
        payload = b"legacy bytes"
        for codec, option in (("gb18030", "gb18030"), ("utf-8", "utf8"), ("cp437", "cp437")):
            name = "école.txt" if codec == "cp437" else "中文.txt"
            simple_zip(path, name.encode(codec), payload, flags=0)
            parsed = run_cli("inspect", path, "--encoding", option)
            assert parsed["members"][0]["path"] == name
            output = pathlib.Path(run_cli("extract", path, "--to", root, "--encoding", option)["outputPath"])
            assert (output / name).read_bytes() == payload
        raw_name = b"old.txt"
        unicode_path = "Unicode 正确中文.txt"
        value = b"\x01" + struct.pack("<I", zlib.crc32(raw_name)) + unicode_path.encode()
        extra = struct.pack("<HH", 0x7075, len(value)) + value
        simple_zip(path, raw_name, payload, flags=0, extra=extra)
        assert run_cli("inspect", path)["members"][0]["path"] == unicode_path
    check("Legacy GB18030/CP437/unflagged UTF-8 and Info-ZIP Unicode Path", encodings)

    def failure_cases():
        for name, kwargs in (("crc", {"bad_crc": True}), ("size", {"declared_size": 1})):
            path = root / (name + ".zip")
            simple_zip(path, b"file.bin", b"payload" * 50000, method=8, **kwargs)
            run_cli("extract", path, "--to", root, expected=1)
            assert not (root / name).exists()
            assert not list(root.glob(".crosszip-*"))
        path = root / "unsafe.zip"
        for name in (b"../outside", b"/outside", b"a/../../outside", b"a//outside", b"nul\x00name"):
            simple_zip(path, name, b"bad")
            assert not run_cli("inspect", path, expected=2)["canProceed"]
        for name in (b"C:/outside", b"NUL.txt", b"trailing.", b"a\\b.txt"):
            simple_zip(path, name, b"original bytes")
            parsed = run_cli("inspect", path)
            assert parsed["canProceed"] and all(issue["severity"] == "warning" for issue in parsed["issues"])
            result = pathlib.Path(run_cli("extract", path, "--to", root)["outputPath"])
            assert (result / name.decode()).read_bytes() == b"original bytes"
        simple_zip(path, b"secret", b"", flags=0x801)
        assert not run_cli("inspect", path, expected=2)["canProceed"]
        simple_zip(path, b"unsupported", b"", method=12)
        assert not run_cli("inspect", path, expected=2)["canProceed"]
        with zipfile.ZipFile(path, "w") as writer:
            writer.writestr("A/one.txt", b"one")
            writer.writestr("a/two.txt", b"two")
        parsed = run_cli("inspect", path)
        assert parsed["canProceed"] and parsed["issues"]
        run_cli("verify", path)
        probe = root / "CaseSensitivityProbe"
        probe.write_bytes(b"probe")
        try:
            if (root / "casesensitivityprobe").exists():
                run_cli("extract", path, "--to", root, expected=1)
            else:
                run_cli("extract", path, "--to", root)
        finally:
            probe.unlink()
        with zipfile.ZipFile(path, "w") as writer:
            writer.writestr("a", b"file")
            writer.writestr("a/two.txt", b"file below a file")
        assert not run_cli("inspect", path, expected=2)["canProceed"]
        assert not (root.parent / "outside").exists()
    check("Corrupt payloads, false sizes, unsafe paths, conflicts and unsupported archives roll back", failure_cases)

    def damaged_index():
        path = root / "damaged.zip"
        simple_zip(path, b"a", b"data")
        valid = path.read_bytes()
        central_offset = valid.index(b"PK\x01\x02")
        mutations = [valid[:-1], valid[:-22], valid[:central_offset] + valid[central_offset+1:]]
        edited = bytearray(valid)
        struct.pack_into("<HH", edited, len(edited)-14, 2, 2)
        mutations.append(edited)
        for data in mutations:
            path.write_bytes(data)
            run_cli("verify", path, expected=1)
    check("Truncated/incorrect central directory is rejected", damaged_index)

    def timestamps():
        for zone_number, zone in enumerate(("UTC", "Asia/Shanghai", "America/New_York")):
            for season_number, instant in enumerate((1767268800, 1782907200)):
                key = f"{zone_number}-{season_number}"
                folder = root / ("timestamp-" + key)
                folder.mkdir()
                file = folder / "readme.txt"
                file.write_bytes(b"timestamp check")
                os.utime(file, (instant, instant))
                os.utime(folder, (instant, instant))
                archive = root / ("time-" + key + ".zip")
                env = dict(os.environ, TZ=zone)
                run_cli("pack", "--output", archive, folder, env=env)
                expected_wall = datetime.fromtimestamp(instant, ZoneInfo(zone))
                with zipfile.ZipFile(archive) as reader:
                    fields = reader.getinfo(folder.name + "/readme.txt").date_time
                    assert fields == (expected_wall.year, expected_wall.month, expected_wall.day,
                                      expected_wall.hour, expected_wall.minute, expected_wall.second // 2 * 2), (zone, fields)
                output = pathlib.Path(run_cli("extract", archive, "--to", root, env=env)["outputPath"])
                for result in (output / folder.name, output / folder.name / "readme.txt"):
                    assert abs(result.stat().st_mtime - instant) < 2, (zone, result.stat().st_mtime, instant)
    check("DOS timestamps: UTC/Shanghai/New York winter and summer preserve same-zone mtime", timestamps)

report = {"generated_at": datetime.now(ZoneInfo("Asia/Shanghai")).isoformat(),
          "status": "passed", "checks": checks, "windows_explorer": "pending real Windows 10/11 verification"}
args.report.parent.mkdir(parents=True, exist_ok=True)
args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(f"{len(checks)} groups passed. Report: {args.report}")

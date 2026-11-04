#!/usr/bin/env python3
"""Compare a Windows-created ZIP extracted on Mac against the acceptance manifest."""
import argparse
import hashlib
import json
import pathlib
import unicodedata

parser = argparse.ArgumentParser()
parser.add_argument("--expected", type=pathlib.Path, required=True)
parser.add_argument("--extracted", type=pathlib.Path, required=True)
args = parser.parse_args()
expected = json.loads(args.expected.read_text(encoding="utf-8-sig"))
root = args.extracted.resolve()
if not root.is_dir():
    raise SystemExit("解压目录不存在或不是文件夹")
actual_files = {}
actual_directories = set()
for path in root.rglob("*"):
    relative = unicodedata.normalize("NFC", path.relative_to(root).as_posix())
    if path.is_symlink():
        raise SystemExit(f"Unexpected symlink: {relative}")
    if path.is_dir():
        if relative in actual_directories:
            raise SystemExit(f"Unicode 规范化后目录重名：{relative}")
        actual_directories.add(relative)
    elif path.is_file():
        if relative in actual_files:
            raise SystemExit(f"Unicode 规范化后文件重名：{relative}")
        with path.open("rb") as handle:
            hasher = hashlib.sha256()
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                hasher.update(chunk)
        actual_files[relative] = (path.stat().st_size, hasher.hexdigest())
    else:
        raise SystemExit(f"不支持的文件类型：{relative}")
expected_files = {item["path"]: (item["size"], item["sha256"]) for item in expected["files"]}
if actual_files != expected_files:
    raise SystemExit("文件路径、数量、大小或 SHA-256 不符")
if actual_directories != set(expected["directories"]):
    raise SystemExit("目录数量或空目录不符")
print("PASS: Windows → Mac 内容与原始清单一致。请另行记录压缩工具和 Windows 版本。")

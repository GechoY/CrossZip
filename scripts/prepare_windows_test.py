#!/usr/bin/env python3
"""Create a portable acceptance package; it does not claim Windows execution."""
import argparse
import hashlib
import json
import pathlib
import subprocess
import tempfile
import unicodedata

parser = argparse.ArgumentParser()
parser.add_argument("--cli", required=True, type=pathlib.Path)
parser.add_argument("--destination", type=pathlib.Path)
parser.add_argument("--multiple", action="store_true", help="验证多个输入统一放入一个外层目录")
args = parser.parse_args()
destination = (args.destination or pathlib.Path("dist/WindowsAcceptance") / ("MultipleFiles" if args.multiple else "")).resolve()
destination.mkdir(parents=True, exist_ok=True)
archive = destination / "CrossZip-WindowsTest.zip"
if archive.exists():
    archive.unlink()
with tempfile.TemporaryDirectory(prefix="CrossZipWindows-") as temporary:
    root = pathlib.Path(temporary)
    source = root / "跨系统资料"
    (source / "空文件夹").mkdir(parents=True)
    (source / "data").mkdir()
    files = {"中文 文件.txt": "Mac 与 Windows 文件交换\n".encode(),
             "emoji 🧪.txt": "English 中文 🙂\n".encode(), "zero.bin": b"",
             "data/bytes.bin": bytes(range(256)) * 4096,
             ".gitignore": b".build/\n", "._ordinary.txt": b"ordinary file; keep it\n"}
    for path, data in files.items():
        (source / path).write_bytes(data)
    name = "项目代码" if args.multiple else source.name
    inputs = list(source.iterdir()) if args.multiple else [source]
    command = [str(args.cli.resolve()), "pack", "--quiet", "--output", str(archive)]
    if args.multiple: command += ["--root", name]
    subprocess.run(command + [str(item) for item in inputs], check=True, capture_output=True)
    expected = {"archive": archive.name, "windows_status": "pending",
                "files": [{"path": unicodedata.normalize("NFC", name + "/" + relative),
                           "size": len(data), "sha256": hashlib.sha256(data).hexdigest()} for relative, data in sorted(files.items())],
                "directories": [name, name + "/空文件夹", name + "/data"]}
    (destination / "expected.json").write_text(json.dumps(expected, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
project = pathlib.Path(__file__).resolve().parent.parent
for name in ("Verify-Windows.ps1", "README.txt"):
    content = (project / "WindowsAcceptance" / name).read_text(encoding="utf-8-sig")
    if args.multiple and name == "README.txt":
        content = "本场景：多选原文件与文件夹，ZIP 内统一包含一个“项目代码”外层目录。\n\n" + content.replace("跨系统资料", "项目代码")
    (destination / name).write_text(content, encoding="utf-8-sig" if name.endswith(".ps1") else "utf-8")
print(destination)

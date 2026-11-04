#!/usr/bin/env python3
"""Reproducible local comparisons; elapsed time includes content verification."""
import argparse
import json
import random
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--cli', required=True, type=Path)
parser.add_argument('--baseline-cli', type=Path)
parser.add_argument('--report', type=Path, default=Path('test-artifacts/compression-benchmark.json'))
args = parser.parse_args()
project = Path(__file__).resolve().parent.parent
rows = []

with tempfile.TemporaryDirectory(prefix='CrossZip-Benchmark-') as temporary:
    root = Path(temporary)
    code = root / 'code'
    shutil.copytree(project / 'Sources', code)
    # Avoid timing dependencies/compilation; only Swift/C interface source text.
    mixed = root / 'mixed'
    shutil.copytree(code, mixed / 'code')
    rng = random.Random(20261104)
    binary = bytes(rng.getrandbits(8) for _ in range(1024 * 1024))
    (mixed / 'random.bin').write_bytes(binary)
    (mixed / 'table.csv').write_bytes(b'channel,distance,value\r\n1,100,42\r\n' * 16000)
    png = project / 'test-artifacts/ui-fixtures/项目资料/设计稿/界面截图.png'
    if png.exists(): shutil.copy2(png, mixed / 'image.png')
    packed = root / 'incompressible'
    packed.mkdir(); (packed / 'random.bin').write_bytes(binary)
    for source in [code, mixed, packed]:
        total = sum(p.stat().st_size for p in source.rglob('*') if p.is_file())
        for fmt in ['zip', '7z', 'tar', 'tar.gz', 'tar.bz2', 'tar.xz']:
            for level in ([0] if fmt == 'tar' else [1, 6, 9]):
                output = root / f'{source.name}-{fmt}-{level}.{fmt}'
                command = [str(args.cli.resolve()), 'pack', '--quiet', '--output', str(output), '--format', fmt]
                if level: command += ['--level', str(level)]
                started = time.monotonic()
                result = subprocess.run(command + [str(source)], capture_output=True, text=True)
                if result.returncode: raise RuntimeError(result.stderr)
                size = output.stat().st_size
                rows.append({'dataset': source.name, 'format': fmt, 'level': level,
                             'source_bytes': total, 'archive_bytes': size, 'archive_to_input_ratio': round(size / total, 6),
                             'saved_percent': round((1 - size / total) * 100, 2),
                             'seconds_with_verification': round(time.monotonic() - started, 4)})
        if args.baseline_cli:
            output = root / f'{source.name}-baseline.zip'
            started = time.monotonic()
            result = subprocess.run([str(args.baseline_cli.resolve()), 'pack', '--quiet', '--output', str(output), str(source)],
                                    capture_output=True, text=True)
            if result.returncode: raise RuntimeError(result.stderr)
            rows.append({'dataset': source.name, 'format': 'zip-1.4.1', 'level': 'fixed', 'source_bytes': total,
                         'archive_bytes': output.stat().st_size,
                         'saved_percent': round((1 - output.stat().st_size / total) * 100, 2),
                         'seconds_with_verification': round(time.monotonic() - started, 4)})
        print('Completed:', source.name, flush=True)

report = {'rows': rows, 'scope': 'Local reproducible examples; results depend on content. Timings include verification. Level 9 selects the smallest of presets 9/6/1.',
          'settings': {'zip': 'Deflate 1/6/9', '7z': 'LZMA2 1/6/9', 'tar': 'no data compression',
                       'tar.gz': 'gzip 1/6/9', 'tar.bz2': 'bzip2 1/6/9', 'tar.xz': 'XZ/LZMA2 1/6/9'}}
args.report.parent.mkdir(parents=True, exist_ok=True)
args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(args.report)

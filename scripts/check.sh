#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p test-artifacts
bash scripts/build_native.sh
swift test
bash scripts/build_app.sh
python3 scripts/test_interop.py --cli dist/crosszip-cli
python3 scripts/test_multiformat.py --cli dist/crosszip-cli
python3 scripts/test_verify_return.py
python3 scripts/prepare_windows_test.py --cli dist/crosszip-cli
python3 scripts/prepare_windows_test.py --cli dist/crosszip-cli --multiple

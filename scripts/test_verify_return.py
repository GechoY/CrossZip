#!/usr/bin/env python3
"""Regression tests for acceptance validation, including optimized Python execution."""
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = pathlib.Path(__file__).resolve().parent


class VerifyReturnTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="CrossZipReturnTests-")
        self.addCleanup(self.temporary.cleanup)
        self.base = pathlib.Path(self.temporary.name)
        self.extracted = self.base / "extracted"
        self.extracted.mkdir()
        (self.extracted / "empty").mkdir()
        (self.extracted / "sample.txt").write_bytes(b"hello")
        self.expected = self.base / "expected.json"
        self.expected.write_text(json.dumps({
            "files": [{"path": "sample.txt", "size": 5, "sha256": hashlib.sha256(b"hello").hexdigest()}],
            "directories": ["empty"],
        }), encoding="utf-8")

    def verify(self, optimized):
        arguments = [sys.executable]
        if optimized:
            arguments.append("-O")
        arguments += [str(SCRIPTS / "verify_return.py"), "--expected", str(self.expected),
                      "--extracted", str(self.extracted)]
        return subprocess.run(arguments, capture_output=True, text=True)

    def assertRejectedInBothModes(self):
        for optimized in (False, True):
            with self.subTest(optimized=optimized):
                result = self.verify(optimized)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertNotIn("PASS:", result.stdout)

    def testMatchingTreePassesInBothModes(self):
        for optimized in (False, True):
            with self.subTest(optimized=optimized):
                result = self.verify(optimized)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("PASS:", result.stdout)

    def testEmptyOutputCannotReportSuccess(self):
        (self.extracted / "sample.txt").unlink()
        (self.extracted / "empty").rmdir()
        self.assertRejectedInBothModes()

    def testSameSizeWrongContentIsRejected(self):
        (self.extracted / "sample.txt").write_bytes(b"wrong")
        self.assertRejectedInBothModes()

    def testMissingDirectoryIsRejected(self):
        (self.extracted / "empty").rmdir()
        self.assertRejectedInBothModes()

    def testExtraDirectoryIsRejected(self):
        (self.extracted / "extra").mkdir()
        self.assertRejectedInBothModes()

    def testMissingOutputPathIsRejected(self):
        self.extracted = self.base / "missing"
        self.assertRejectedInBothModes()

    def testSymlinkIsRejected(self):
        target = self.base / "target.txt"
        target.write_bytes(b"hello")
        (self.extracted / "sample.txt").unlink()
        (self.extracted / "sample.txt").symlink_to(target)
        self.assertRejectedInBothModes()

    def testInteropSuiteRefusesOptimizedPython(self):
        result = subprocess.run([sys.executable, "-O", str(SCRIPTS / "test_interop.py")],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("优化模式", result.stderr)
        self.assertNotIn("PASS", result.stdout)


if __name__ == "__main__":
    unittest.main()

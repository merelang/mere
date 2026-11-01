#!/usr/bin/env python3
"""Check that an executable reporting the right version can still be rejected."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

CHECKER = Path(__file__).with_name("release_runtime_check.sh").resolve()
FAKE = r'''#!/bin/sh
case "$1" in
  --version)
    if [ "$FAILURE" = version ]; then echo 'mere v0.0.0'
    else echo 'mere v9.8.7'; fi
    ;;
  -c|-ll|-w)
    [ "$FAILURE" != "exit:$1" ] || exit 17
    [ "$FAILURE" != "empty:$1" ] || exit 0
    [ "$FAILURE" != "stderr:$1" ] || echo 'unexpected diagnostic' >&2
    echo 'generated code'
    ;;
  *)
    case "$FAILURE" in
      version-only) exit 0 ;;
      program-exit) echo 'program crashed' >&2; exit 17 ;;
      program-output) echo 'wrong answer'; exit 0 ;;
      program-stderr) echo 'unexpected diagnostic' >&2 ;;
    esac
    printf 'thread-ok\n42\n'
    ;;
esac
'''


class RuntimeCheckTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.binary = Path(self.tmp.name) / "mere"
        self.binary.write_text(FAKE)
        self.binary.chmod(0o755)

    def check(self, failure=""):
        return subprocess.run(
            ["sh", str(CHECKER), "--native", str(self.binary), "9.8.7"],
            env=dict(os.environ, FAILURE=failure), capture_output=True,
            text=True, timeout=20,
        )

    def rejected(self, failure, diagnostic):
        result = self.check(failure)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(diagnostic, result.stdout + result.stderr)

    def test_success(self):
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("passed", result.stdout)

    def test_wrong_version(self):
        self.rejected("version", "mere v0.0.0")

    def test_version_only(self):
        self.rejected("version-only", "thread-ok")

    def test_program_exit(self):
        self.rejected("program-exit", "program failed")

    def test_program_output(self):
        self.rejected("program-output", "wrong answer")

    def test_program_stderr(self):
        self.rejected("program-stderr", "unexpected stderr")

    def test_codegen_failures(self):
        for backend in ("-c", "-ll", "-w"):
            for failure, diagnostic in (
                ("exit", "emission failed"),
                ("empty", "emitted nothing"),
                ("stderr", "unexpected stderr"),
            ):
                with self.subTest(backend=backend, failure=failure):
                    self.rejected(failure + ":" + backend, backend + " " + diagnostic)

    def test_not_executable(self):
        self.binary.chmod(0o644)
        self.rejected("", "not executable")


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Exercise the real installer with isolated downloads and install targets."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

INSTALLER = Path(__file__).resolve().with_name("install.sh")
TAG = "v9.8.7"
BASE = "https://github.com/merelang/mere/releases"
ASSETS = ("mere-linux-x86_64", "mere-macos-arm64")

CURL = r'''
import os
import json
from pathlib import Path
import shutil
import signal
import sys

args = sys.argv[1:]
url = next(arg for arg in args if arg.startswith("https://"))
with open(os.environ["MERE_TEST_REQUESTS"], "a") as log:
    log.write(url + "\n")
mode = os.environ.get("MERE_TEST_FAILURE", "")
base = "https://github.com/merelang/mere/releases"
if url == base + "/latest":
    if mode in ("resolve", "api-resolve"):
        sys.exit(22)
    print(os.environ.get("MERE_TEST_RELEASE", base + "/tag/v9.8.7"), end="")
    sys.exit(0)
api = "https://api.github.com/repos/merelang/mere/releases"
if url == api + "/latest":
    if mode != "api-resolve": sys.exit(44)
    print(os.environ["MERE_TEST_METADATA"])
    sys.exit(0)
if url == api + "/tags/v9.8.7":
    if not mode.startswith("api"):
        sys.exit(44)
    output = args[args.index("-o") + 1]
    Path(output).write_text(os.environ["MERE_TEST_METADATA"])
    sys.exit(22 if mode == "api-metadata-failed" else 0)
if url.startswith(api + "/assets/"):
    if not mode.startswith("api"):
        sys.exit(44)
    name = url.rsplit("/", 1)[-1]
    output = args[args.index("-o") + 1]
    source = os.environ["MERE_TEST_SUMS" if name == "1" else "MERE_TEST_BINARY"]
    shutil.copyfile(source, output)
    sys.exit(22 if mode == "api-download-failed" else 0)
if mode.startswith("api"):
    sys.exit(22)
prefix = base + "/download/v9.8.7/"
legacy = base + "/latest/download/"
if url.startswith(legacy):
    name = url[len(legacy):]
elif url.startswith(prefix):
    name = url[len(prefix):]
else:
    sys.exit(44)
output = args[args.index("-o") + 1]
if name == "SHA256SUMS":
    shutil.copyfile(os.environ["MERE_TEST_SUMS"], output)
    sys.exit(22 if mode == "manifest" else 0)
if name not in ("mere-linux-x86_64", "mere-macos-arm64"):
    sys.exit(44)
shutil.copyfile(os.environ["MERE_TEST_BINARY"], output)
if mode == "signal":
    os.kill(os.getppid(), signal.SIGTERM)
sys.exit(22 if mode == "binary" else 0)
'''


class InstallerCheck(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mere-install-check-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.bindir = self.root / "install with spaces"
        self.bindir.mkdir()
        self.target = self.bindir / "mere"
        self.old = b"#!/bin/sh\nprintf 'existing compiler\\n'\n"
        self.target.write_bytes(self.old)
        self.target.chmod(0o751)
        self.binary = self.root / "download"
        self.sums = self.root / "SHA256SUMS"
        self.requests = self.root / "requests"
        self.executions = self.root / "executions"
        self.env = dict(os.environ, PATH=str(self.tools), MERE_BINDIR=str(self.bindir),
                        MERE_TEST_OS="Linux", MERE_TEST_ARCH="x86_64",
                        MERE_TEST_BINARY=str(self.binary), MERE_TEST_SUMS=str(self.sums),
                        MERE_TEST_REQUESTS=str(self.requests),
                        MERE_TEST_EXECUTIONS=str(self.executions))
        for name in ("mkdir", "mktemp", "rm", "sed", "awk", "chmod", "mv", "perl"):
            path = shutil.which(name)
            if path:
                (self.tools / name).symlink_to(path)
        self.hasher = next((name for name in ("sha256sum", "shasum")
                            if shutil.which(name)), None)
        self.assertIsNotNone(self.hasher, "a SHA-256 tool is required for installer checks")
        (self.tools / self.hasher).symlink_to(shutil.which(self.hasher))
        self.write_tool("uname", 'case "$1" in\n'
                        '  -s) printf "%s\\n" "$MERE_TEST_OS" ;;\n'
                        '  -m) printf "%s\\n" "$MERE_TEST_ARCH" ;;\nesac\n')
        helper = self.root / "curl.py"
        helper.write_text(CURL)
        self.write_tool("curl", "exec " + shlex.quote(sys.executable) + " "
                        + shlex.quote(str(helper)) + ' "$@"\n')
        self.metadata = {"tag_name": TAG, "body": '\"name\": \"mere-linux-x86_64\" {}',
                         "assets": [{"name": name, "id": i,
                                     "uploader": {"name": "SHA256SUMS", "id": 99}}
                                    for i, name in enumerate(("SHA256SUMS",) + ASSETS, 1)]}
        self.env["MERE_TEST_METADATA"] = json.dumps(self.metadata)
        self.make_binary()

    def write_tool(self, name, body):
        path = self.tools / name
        if path.is_symlink():
            path.unlink()
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o755)

    def make_binary(self, version="9.8.7", output="install-ok", version_exit=0, run_exit=0):
        self.binary.write_text(
            '#!/bin/sh\nprintf "%s\\n" "$1" >> "$MERE_TEST_EXECUTIONS"\n'
            'if [ "$1" = --version ]; then\n'
            "  printf '%s\\n' " + shlex.quote("mere v" + version) + "\n"
            "  exit " + str(version_exit) + "\nfi\n"
            "printf '%s\\n' " + shlex.quote(output) + "\nexit " + str(run_exit) + "\n")
        self.update_sums()

    def update_sums(self):
        digest = hashlib.sha256(self.binary.read_bytes()).hexdigest()
        self.sums.write_text("".join(digest + "  " + name + "\n" for name in ASSETS))

    def run_install(self):
        return subprocess.run(["/bin/sh", str(INSTALLER)], env=self.env,
                              capture_output=True, text=True, timeout=15)

    def assert_failure(self):
        result = self.run_install()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Installed:", result.stdout)
        self.assertEqual(self.target.read_bytes(), self.old)
        self.assertEqual(self.target.stat().st_mode & 0o777, 0o751)
        self.assertEqual(list(self.bindir.glob(".mere-install.*")), [])
        return result

    def assert_success(self, asset=ASSETS[0]):
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Installed: mere v9.8.7", result.stdout)
        self.assertEqual(self.target.read_bytes(), self.binary.read_bytes())
        self.assertEqual(self.target.stat().st_mode & 0o777, 0o755)
        self.assertEqual(list(self.bindir.glob(".mere-install.*")), [])
        requests = [BASE + "/latest", BASE + "/download/" + TAG + "/SHA256SUMS",
                    BASE + "/download/" + TAG + "/" + asset]
        if self.env.get("MERE_TEST_FAILURE", "").startswith("api"):
            api = "https://api.github.com/repos/merelang/mere/releases"
            requests = requests[:2] + [api + "/tags/" + TAG, api + "/assets/1",
                                      requests[2], api + "/assets/" + ("2" if asset == ASSETS[0] else "3")]
        if self.env.get("MERE_TEST_FAILURE") == "api-resolve":
            requests.insert(1, api + "/latest")
        self.assertEqual(self.requests.read_text().splitlines(), requests)
        calls = self.executions.read_text().splitlines()
        self.assertEqual(calls[0], "--version")
        self.assertEqual(len(calls), 2)
        self.assertTrue(calls[1].endswith("/smoke.mere"))

    def test_api_latest_resolution(self):
        self.env["MERE_TEST_FAILURE"] = "api-resolve"
        self.assert_success()

    def test_api_fallback_verified_update(self):
        self.env["MERE_TEST_FAILURE"] = "api"
        self.assert_success()

    def test_api_fallback_macos_pretty_metadata(self):
        self.env.update(MERE_TEST_FAILURE="api", MERE_TEST_OS="Darwin", MERE_TEST_ARCH="arm64",
                        MERE_TEST_METADATA=json.dumps(self.metadata, indent=2))
        self.assert_success(ASSETS[1])

    def test_api_fallback_refuses_wrong_metadata(self):
        for mode in ("tag", "missing", "duplicate", "invalid-id", "quoted-id", "truncated"):
            with self.subTest(mode=mode):
                metadata = json.loads(json.dumps(self.metadata))
                if mode == "tag": metadata["tag_name"] = "v9.8.6"
                if mode == "missing": metadata["assets"] = metadata["assets"][1:]
                if mode == "duplicate": metadata["assets"] += metadata["assets"]
                if mode == "invalid-id": metadata["assets"][0]["id"] = -1
                if mode == "quoted-id": metadata["assets"][0]["id"] = "1"
                text = json.dumps(metadata)
                if mode == "truncated": text = text[:-1]
                self.env.update(MERE_TEST_FAILURE="api", MERE_TEST_METADATA=text)
                self.assert_failure()
                self.assertFalse(self.executions.exists())

    def test_api_fallback_failures_preserve_existing_binary(self):
        for mode in ("api-metadata-failed", "api-download-failed"):
            with self.subTest(mode=mode):
                self.env["MERE_TEST_FAILURE"] = mode
                self.assert_failure()
                self.assertFalse(self.executions.exists())

    def test_api_fallback_checksums_precede_execution(self):
        self.env["MERE_TEST_FAILURE"] = "api"
        self.sums.write_text("0" * 64 + "  " + ASSETS[0] + "\n")
        self.assert_failure()
        self.assertFalse(self.executions.exists())

    def test_verified_update(self):
        self.assert_success()

    def test_fresh_install(self):
        self.target.unlink()
        self.bindir.rmdir()
        self.assert_success()

    def test_macos_arm64(self):
        self.env.update(MERE_TEST_OS="Darwin", MERE_TEST_ARCH="arm64")
        self.assert_success(ASSETS[1])

    def test_shasum_fallback(self):
        shasum = shutil.which("shasum")
        if not shasum:
            self.skipTest("shasum is not installed")
        (self.tools / self.hasher).unlink()
        (self.tools / "shasum").symlink_to(shasum)
        self.assert_success()

    def test_unsupported_platforms_do_not_download(self):
        for os_name, arch in (("Darwin", "x86_64"), ("Linux", "arm64")):
            with self.subTest(os=os_name, arch=arch):
                self.env.update(MERE_TEST_OS=os_name, MERE_TEST_ARCH=arch)
                self.assert_failure()
                self.assertFalse(self.requests.exists())

    def test_failed_downloads_preserve_existing_binary(self):
        for failure in ("resolve", "manifest", "binary", "signal"):
            with self.subTest(failure=failure):
                self.env["MERE_TEST_FAILURE"] = failure
                self.assert_failure()
                self.assertFalse(self.executions.exists())

    def test_unexpected_release_is_rejected(self):
        for url in ("https://example.org/tag/v9.8.7", BASE + "/tag/not-a-version"):
            with self.subTest(url=url):
                self.env["MERE_TEST_RELEASE"] = url
                self.assert_failure()
                self.assertFalse(self.executions.exists())

    def test_invalid_checksums_never_execute_the_download(self):
        valid = self.sums.read_text()
        for manifest in ("", "0" * 64 + "  " + ASSETS[0] + "\n",
                         "invalid  " + ASSETS[0] + "\n", valid + valid):
            with self.subTest(manifest=manifest):
                self.sums.write_text(manifest)
                self.assert_failure()
                self.assertFalse(self.executions.exists())

    def test_no_checksum_tool_preserves_existing_binary(self):
        (self.tools / self.hasher).unlink()
        self.assert_failure()
        self.assertFalse(self.requests.exists())

    def test_checksum_tool_failure_preserves_existing_binary(self):
        digest = hashlib.sha256(self.binary.read_bytes()).hexdigest()
        self.write_tool(self.hasher, "printf '%s\\n' " + shlex.quote(digest) + "\nexit 1\n")
        self.assert_failure()
        self.assertFalse(self.executions.exists())

    def test_invalid_executable_preserves_existing_binary(self):
        self.binary.write_bytes(b"not-a-valid-executable\n")
        self.update_sums()
        self.assert_failure()

    def test_wrong_version_preserves_existing_binary(self):
        self.make_binary(version="9.8.6")
        self.assert_failure()

    def test_failed_version_command_preserves_existing_binary(self):
        self.make_binary(version_exit=1)
        self.assert_failure()

    def test_failed_program_preserves_existing_binary(self):
        self.make_binary(run_exit=1)
        self.assert_failure()

    def test_wrong_program_output_preserves_existing_binary(self):
        self.make_binary(output="unexpected")
        self.assert_failure()

    def test_failed_rename_preserves_existing_binary(self):
        self.write_tool("mv", "exit 1\n")
        self.assert_failure()

    def test_directory_destination_is_untouched(self):
        self.target.unlink()
        self.target.mkdir()
        marker = self.target / "keep"
        marker.write_text("keep")
        result = self.run_install()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(marker.read_text(), "keep")
        self.assertEqual(list(self.bindir.glob(".mere-install.*")), [])
        self.assertFalse(self.executions.exists())

    def test_failed_update_preserves_symlink(self):
        original = self.root / "original"
        self.target.rename(original)
        self.target.symlink_to(original)
        self.env["MERE_TEST_FAILURE"] = "binary"
        self.assert_failure()
        self.assertTrue(self.target.is_symlink())

    def test_verified_update_replaces_symlink_only(self):
        original = self.root / "original"
        self.target.rename(original)
        self.target.symlink_to(original)
        self.assert_success()
        self.assertFalse(self.target.is_symlink())
        self.assertEqual(original.read_bytes(), self.old)


if __name__ == "__main__":
    unittest.main(verbosity=2)

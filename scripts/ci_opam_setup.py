#!/usr/bin/env python3
"""Populate setup-ocaml's tool cache using signed GitHub release API assets."""
import argparse
import hashlib
import os
from pathlib import Path
import platform
import re
from ci_release_asset import api, verify_asset
import shutil
import subprocess
import tempfile
import urllib.request

# Matches the pinned setup-ocaml implementation, including its signing key.
SIGNER = "92C526AE50DF39470EB2911BED4CF1CA67CBAA92"
KEY_URL = "https://opam.ocaml.org/opam-dev-pubkey.pgp"


def target(system, machine):
    systems = {"Linux": "linux", "Darwin": "macos"}
    architectures = {"x86_64": "x86_64", "amd64": "x86_64",
                     "arm64": "arm64", "aarch64": "arm64"}
    if system not in systems or machine.lower() not in architectures:
        raise ValueError("unsupported opam runner platform")
    return systems[system], architectures[machine.lower()]


def select_release(releases, system, arch):
    candidates = []
    for release in releases:
        tag = release.get("tag_name", "")
        if not re.fullmatch(r"\d+\.\d+\.\d+", tag):
            continue
        version = tuple(map(int, tag.split(".")))
        if version < (2, 7, 0) and not release.get("draft") and not release.get("prerelease"):
            candidates.append((version, release))
    for _, release in sorted(candidates, key=lambda item: item[0], reverse=True):
        version = release["tag_name"]
        name = f"opam-{version}-{arch}-{system}"
        assets = {asset["name"]: asset for asset in release["assets"]}
        if name in assets:
            if name + ".sig" not in assets:
                raise ValueError("selected opam release has no detached signature")
            return version, assets[name], assets[name + ".sig"]
    raise ValueError("no supported stable opam release")


def verify_status(status):
    signatures = [line.split() for line in status.splitlines()
                  if line.startswith("[GNUPG:] VALIDSIG ")]
    if not any(parts[-1] == SIGNER for parts in signatures):
        raise ValueError("opam signature has an unexpected primary key")


def verify_signature(binary, signature, key, work):
    home = work / "gpg"
    home.mkdir(mode=0o700)
    base = ["gpg", "--batch", "--homedir", str(home)]
    subprocess.run(base + ["--import", str(key)], capture_output=True, check=True, timeout=30)
    result = subprocess.run(base + ["--status-fd", "1", "--verify", str(signature), str(binary)],
                            capture_output=True, text=True, check=True, timeout=30)
    verify_status(result.stdout)


def publish(binary, cache, version, arch):
    destination = cache / "opam" / version / arch
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=destination, delete=False) as output:
        temporary = Path(output.name)
    try:
        shutil.copyfile(binary, temporary)
        temporary.chmod(0o755)
        temporary.replace(destination / "opam")
        (destination.parent / (arch + ".complete")).touch()
    finally:
        temporary.unlink(missing_ok=True)


def install(cache):
    system, arch = target(platform.system(), platform.machine())
    releases = []
    for page in range(1, 11):
        batch = api(f"repos/ocaml/opam/releases?per_page=100&page={page}")
        releases.extend(batch)
        if len(batch) < 100:
            break
    else:
        raise ValueError("opam release listing exceeded its page bound")
    version, binary_asset, signature_asset = select_release(releases, system, arch)
    with tempfile.TemporaryDirectory(prefix="mere-opam-") as temporary:
        work = Path(temporary)
        binary, signature, key = (work / name for name in ["opam", "opam.sig", "key.pgp"])
        for path, asset in [(binary, binary_asset), (signature, signature_asset)]:
            if not isinstance(asset.get("id"), int) or asset["id"] <= 0:
                raise ValueError("invalid release asset ID")
            api(f"repos/ocaml/opam/releases/assets/{asset['id']}", path)
            verify_asset(path, asset)
        with urllib.request.urlopen(KEY_URL, timeout=30) as response:
            key.write_bytes(response.read())
        verify_signature(binary, signature, key, work)
        publish(binary, cache, version, arch)
    print(f"Verified opam {version} {arch}-{system}: release API digests and signing key {SIGNER}")


def self_test():
    from unittest.mock import patch
    failures = 0

    def rejects(operation):
        nonlocal failures
        try:
            operation()
        except (ValueError, OSError, subprocess.SubprocessError):
            failures += 1
        else:
            raise AssertionError("opam bootstrap negative control was accepted")

    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        binary = root / "binary"
        binary.write_bytes(b"verified bytes")
        asset = {"id": 1, "size": 14, "digest": "sha256:" + hashlib.sha256(binary.read_bytes()).hexdigest()}
        verify_asset(binary, asset)
        for change in [{"id": -1}, {"size": 15}, {"digest": None}, {"digest": "sha256:" + "0" * 64}]:
            rejects(lambda change=change: verify_asset(binary, dict(asset, **change)))
        binary.write_bytes(b"modified bytes")
        rejects(lambda: verify_asset(binary, asset))
        verify_status("[GNUPG:] VALIDSIG signing-key 0 0 0 0 0 0 0 0 " + SIGNER)
        for status in ["", "VALIDSIG " + SIGNER, "[GNUPG:] VALIDSIG " + "0" * 40]:
            rejects(lambda status=status: verify_status(status))
        rejects(lambda: target("Windows", "x86_64"))
        rejects(lambda: target("Linux", "unknown"))
        name = "opam-2.6.1-x86_64-linux"
        release = {"tag_name": "2.6.1", "assets": [{"name": name}, {"name": name + ".sig"}]}
        assert select_release([dict(release, tag_name="2.7.0"), release], "linux", "x86_64")[0] == "2.6.1"
        rejects(lambda: select_release([dict(release, assets=[{"name": name}])], "linux", "x86_64"))
        rejects(lambda: select_release([dict(release, prerelease=True)], "linux", "x86_64"))
        rejects(lambda: select_release([dict(release, draft=True)], "linux", "x86_64"))
        # A failed copy must not expose an executable or completion marker.
        cache = root / "failed-cache"
        with patch("shutil.copyfile", side_effect=OSError("copy failure")):
            rejects(lambda: publish(binary, cache, "2.6.1", "x86_64"))
        assert not list(cache.rglob("*.complete")) and not (cache / "opam/2.6.1/x86_64/opam").exists()
        publish(binary, root / "cache", "2.6.1", "x86_64")
        assert (root / "cache/opam/2.6.1/x86_64/opam").read_bytes() == binary.read_bytes()
        assert (root / "cache/opam/2.6.1/x86_64.complete").is_file()
    # Verify failure propagation through the entire acquisition sequence.
    import contextlib
    import io
    payloads = {1: b"verified bytes", 2: b"signature"}
    assets = [{"name": name + suffix, "id": i, "size": len(payloads[i]),
               "digest": "sha256:" + hashlib.sha256(payloads[i]).hexdigest()}
              for i, suffix in [(1, ""), (2, ".sig")]]
    release = {"tag_name": "2.6.1", "assets": assets}
    with tempfile.TemporaryDirectory() as temporary:
        for mode in ["signature", "gpg", "partial", "success"]:
            cache = Path(temporary) / mode
            marker = cache / "opam/2.6.1/x86_64.complete"
            verified = []

            def fake_api(path, destination=None):
                if destination is None:
                    return [release]
                if mode == "partial":
                    destination.write_bytes(b"partial")
                    raise OSError("interrupted download")
                destination.write_bytes(payloads[int(path.rsplit("/", 1)[-1])])

            def fake_verify(*args):
                assert not marker.exists(), "cache became visible before signature verification"
                if mode == "signature":
                    raise ValueError("bad signature")
                if mode == "gpg":
                    raise subprocess.CalledProcessError(1, "gpg")
                verified.append(True)

            with patch.dict(globals(), api=fake_api, verify_signature=fake_verify,
                            target=lambda *_: ("linux", "x86_64")), \
                 patch("urllib.request.urlopen", side_effect=lambda *_args, **_kwargs: io.BytesIO(b"key")), \
                 contextlib.redirect_stdout(io.StringIO()):
                if mode == "success":
                    install(cache)
                    assert verified == [True] and marker.exists()
                else:
                    rejects(lambda: install(cache))
                    assert not marker.exists() and not (marker.parent / "x86_64/opam").exists()
    print(f"ci_opam_setup: {failures} rejection controls and atomic cache publication passed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--tool-cache", type=Path, default=os.environ.get("RUNNER_TOOL_CACHE"))
    args = parser.parse_args()
    if args.self_test:
        self_test()
    else:
        if args.tool_cache is None:
            parser.error("RUNNER_TOOL_CACHE or --tool-cache is required")
        install(args.tool_cache)

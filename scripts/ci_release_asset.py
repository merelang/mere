#!/usr/bin/env python3
"""Download a pinned CI tool through the GitHub release API, verifying its bytes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
from urllib.parse import quote


def api(path, destination=None):
    args = ["gh", "api", "--hostname", "github.com", path]
    if destination is not None:
        args[2:2] = ["-H", "Accept: application/octet-stream"]
    # setup-ocaml forces CLI color globally; machine-readable API bytes must
    # stay uncolored even when stdout is redirected.
    environment = dict(os.environ, CLICOLOR_FORCE="0", NO_COLOR="1")
    for attempt in range(2):
        try:
            if destination is None:
                return json.loads(subprocess.check_output(args, timeout=45, env=environment))
            with destination.open("wb") as output:
                subprocess.run(args, stdout=output, check=True, timeout=45, env=environment)
            return
        except (subprocess.SubprocessError, json.JSONDecodeError):
            if attempt:
                raise
            time.sleep(2)


def verify_asset(path, asset):
    if not isinstance(asset.get("id"), int) or asset["id"] <= 0:
        raise ValueError("invalid release asset ID")
    digest = asset.get("digest", "")
    if not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        raise ValueError("release asset has no SHA-256 digest")
    if path.stat().st_size != asset.get("size"):
        raise ValueError("release asset size differs from metadata")
    actual = "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != digest:
        raise ValueError("release asset digest differs from metadata")


def download(repo, tag, name, destination, sha256=None):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise ValueError("invalid repository")
    release = api(f"repos/{repo}/releases/tags/{quote(tag, safe='')}")
    if release.get("tag_name") != tag or release.get("draft") or release.get("prerelease"):
        raise ValueError("expected a published stable release with the pinned tag")
    assets = [asset for asset in release["assets"] if asset["name"] == name]
    if len(assets) != 1:
        raise ValueError("expected exactly one named release asset")
    asset = dict(assets[0])
    if not isinstance(asset.get("id"), int) or asset["id"] <= 0:
        raise ValueError("invalid release asset ID")
    # Older assets predate GitHub's digest metadata. They require an explicit
    # reviewed digest; a pin must also agree with metadata whenever available.
    if sha256 is not None:
        if not re.fullmatch(r"[0-9a-f]{64}", sha256):
            raise ValueError("invalid pinned SHA-256 digest")
        digest = "sha256:" + sha256
        if asset.get("digest") not in (None, digest):
            raise ValueError("pinned digest differs from release metadata")
        asset["digest"] = digest
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".mere-asset-", dir=destination.parent) as temporary:
        partial = Path(temporary) / "download"
        api(f"repos/{repo}/releases/assets/{asset['id']}", partial)
        verify_asset(partial, asset)
        partial.replace(destination)
    print(f"Verified {repo} {tag} {name}: {asset['digest']}")


def self_test():
    import contextlib
    import io
    from unittest.mock import patch
    payload = b"reviewed bytes"
    digest = hashlib.sha256(payload).hexdigest()
    asset = {"id": 1, "name": "tool.tar.gz", "size": len(payload), "digest": "sha256:" + digest}
    release = {"tag_name": "v1.0.0", "assets": [asset]}
    controls = ["tag", "draft", "prerelease", "missing", "duplicate", "id", "size", "digest",
                "no-digest", "pin", "pin-mismatch", "partial", "failed"]
    with tempfile.TemporaryDirectory() as temporary:
        for mode in controls + ["success", "legacy"]:
            destination = Path(temporary) / "tool"
            destination.write_bytes(b"previous verified tool")
            metadata = dict(release, assets=[dict(asset)])
            item = metadata["assets"][0]
            if mode == "tag": metadata["tag_name"] = "v2.0.0"
            if mode in {"draft", "prerelease"}: metadata[mode] = True
            if mode == "missing": metadata["assets"] = []
            if mode == "duplicate": metadata["assets"] *= 2
            if mode == "id": item["id"] = -1
            if mode == "size": item["size"] += 1
            if mode == "digest": item["digest"] = "sha256:" + "0" * 64
            if mode in {"no-digest", "legacy"}: item["digest"] = None
            pin = digest if mode == "legacy" else ("bad" if mode == "pin" else ("0" * 64 if mode == "pin-mismatch" else None))

            def fake_api(path, target=None):
                if target is None: return metadata
                assert destination.read_bytes() == b"previous verified tool"
                target.write_bytes(b"partial" if mode == "partial" else payload)
                if mode == "failed": raise subprocess.CalledProcessError(1, "gh")

            with patch.dict(globals(), api=fake_api), contextlib.redirect_stdout(io.StringIO()):
                try:
                    download("owner/repo", "v1.0.0", "tool.tar.gz", destination, pin)
                except (ValueError, subprocess.SubprocessError):
                    assert mode in controls
                    assert destination.read_bytes() == b"previous verified tool"
                else:
                    assert mode in {"success", "legacy"}
                    assert destination.read_bytes() == payload
            assert sorted(p.name for p in destination.parent.iterdir()) == ["tool"]
    # Bound both request types, including timeout retries and partial-file reset.
    with patch("subprocess.check_output", side_effect=[subprocess.TimeoutExpired("gh", 45), b"{}"] ) as request, \
         patch("time.sleep") as backoff:
        assert api("repos/owner/repo/releases") == {}
        assert request.call_count == 2
        assert all(call.kwargs["timeout"] == 45 and call.kwargs["env"]["CLICOLOR_FORCE"] == "0"
                   and call.kwargs["env"]["NO_COLOR"] == "1" for call in request.call_args_list)
        backoff.assert_called_once_with(2)
    with patch("subprocess.check_output", side_effect=subprocess.TimeoutExpired("gh", 45)) as request, \
         patch("time.sleep"):
        try: api("repos/owner/repo/releases")
        except subprocess.TimeoutExpired: pass
        else: raise AssertionError("unbounded API retry")
        assert request.call_count == 2
    print(f"ci_release_asset: {len(controls)} rejection controls and atomic replacement passed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--repo")
    parser.add_argument("--tag")
    parser.add_argument("--asset")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--sha256")
    args = parser.parse_args()
    if args.self_test:
        self_test()
    else:
        if any(value is None for value in [args.repo, args.tag, args.asset, args.output]):
            parser.error("--repo, --tag, --asset and --output are required")
        download(args.repo, args.tag, args.asset, args.output, args.sha256)

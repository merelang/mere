#!/usr/bin/env python3
"""Check native session-spawn errno and output under descriptor actions."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MERE = os.environ.get("MERE", str(ROOT / "_build/default/bin/mere.exe"))
CC = os.environ.get("CC", "clang")
CASES = [("none", 0)] + [
    (mode, fd) for mode in ["dup-dst", "open", "close"] for fd in [3, 4, 5, 6, 64]
] + [("dup-src", fd) for fd in [1, 2, 3, 4, 5, 6, 64]] + [("dup-chain", 4), ("dup-chain", 6)]


def compile_probe(folder, backend):
    probe = ROOT / "test/tty/spawn_failure_probe.mere"
    source = folder / ("probe." + backend)
    source.write_bytes(subprocess.check_output([MERE, "-" + backend, str(probe)], timeout=60))
    files = [str(source)]
    if backend == "ll":
        ffi = folder / "ffi.c"
        ffi.write_bytes(subprocess.check_output([MERE, "--ffi-c", str(probe)], timeout=60))
        files.append(str(ffi))
    binary = folder / ("probe-" + backend)
    subprocess.run([CC, "-O2", "-w", *files, "-lm", "-lpthread", "-o", str(binary)],
                   check=True, timeout=90)
    return binary


def main():
    count = 0
    with tempfile.TemporaryDirectory(prefix="mere-spawn-channel-") as directory:
        folder = Path(directory)
        for backend in ["c", "ll"]:
            binary = compile_probe(folder, backend)
            for mode, fd in CASES:
                output = folder / (backend + "-" + mode + "-" + str(fd))
                result = subprocess.run(
                    [str(binary), mode, str(fd), str(output), str(folder / "missing-program")],
                    cwd=folder, capture_output=True, timeout=10)
                # Exit 42 means the source descriptor was open before the
                # runtime created its private pipe. It must remain usable.
                statuses = [0, 42] if mode == "dup-src" else [0]
                if mode == "close":
                    expected = [b"-2\n", b"-9\n"]  # exec failure, or already closed
                elif mode == "dup-src" and result.returncode == 0:
                    expected = [b"-9\n"]  # an originally closed source stays closed
                else:
                    expected = [b"-2\n"]
                good = (result.returncode in statuses and result.stdout in expected
                        and not result.stderr)
                contents = output.read_bytes() if output.exists() else None
                if mode == "open":
                    good = good and contents == b""  # no errno bytes in application output
                if not good:
                    raise AssertionError(json.dumps({
                        "backend": backend, "mode": mode, "fd": fd,
                        "returncode": result.returncode, "stdout": repr(result.stdout),
                        "stderr": repr(result.stderr), "file_bytes": repr(contents),
                    }))
                count += 1
    assert count == 50
    print(f"spawn_failure_check: {count} of 50 passed", flush=True)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Exercise partition coverage, ordering, failure and cancellation boundaries."""
from pathlib import Path
import os
import signal
import subprocess
import sys
import tempfile
import time

RUNNER = Path(__file__).with_name("normalize_workers.py")
CORPUS = b"".join(f"{i}\n".encode() for i in range(17))
WORKER = '''from pathlib import Path
import os, sys, time
path = Path(os.environ["NORMALIZE_CORPUS"])
data = path.read_bytes()
mode = MODE
if data.startswith(b"0\\n"):
    time.sleep(0.1)  # Finish the second slice first; retain corpus order.
if mode == "fail":
    sys.stdout.buffer.write(data)
    sys.stdout.flush()
    sys.exit(23)
if mode == "short": data = b"".join(data.splitlines(keepends=True)[:-1])
if mode == "extra": data += b"extra\\n"
if mode == "newline": data = data.rstrip(b"\\n")
if mode == "repeat": path.write_bytes(b"0\\n" * len(data.splitlines()))
if mode == "sleep":
    Path(str(path) + ".pid").write_text(str(os.getpid()))
    time.sleep(60)
sys.stdout.buffer.write(data)
'''


def main():
    checked = 0
    with tempfile.TemporaryDirectory(prefix="normalize-controls-") as tmp:
        root = Path(tmp)
        for jobs in (1, 2):
            for mode in ("ok", "fail", "short", "extra", "newline", "repeat"):
                directory = root / f"{jobs}-{mode}"
                directory.mkdir()
                (directory / "corpus.txt").write_bytes(CORPUS)
                probe = directory / "probe.py"
                probe.write_text(WORKER.replace("MODE", repr(mode)))
                result = subprocess.run([sys.executable, RUNNER, sys.executable, probe,
                                         directory, str(jobs)], capture_output=True, timeout=10)
                if mode == "ok":
                    assert result.returncode == 0, result.stderr
                    assert (directory / "ours_raw.txt").read_bytes() == CORPUS
                else:
                    assert result.returncode != 0, (jobs, mode)
                    assert not (directory / "ours_raw.txt").exists(), (jobs, mode)
                checked += 1
        directory = root / "cancel"
        directory.mkdir()
        (directory / "corpus.txt").write_bytes(CORPUS)
        probe = directory / "probe.py"
        probe.write_text(WORKER.replace("MODE", repr("sleep")))
        process = subprocess.Popen([sys.executable, RUNNER, sys.executable, probe,
                                    directory, "2"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 5
            while True:
                workers = []
                for path in directory.glob("*.pid"):
                    value = path.read_text()
                    if value:
                        workers.append(int(value))
                if len(workers) == 2:
                    break
                assert process.poll() is None and time.monotonic() < deadline
                time.sleep(0.02)
            process.send_signal(signal.SIGTERM)
            process.communicate(timeout=10)
            assert process.returncode != 0
            for pid in workers:
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    pass
                else:
                    raise AssertionError("cancelled normalization worker remains alive")
            checked += 1
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.communicate(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.communicate()
    print(f"normalize_workers: {checked} ordering, coverage, failure and cancellation controls passed")


if __name__ == "__main__":
    main()

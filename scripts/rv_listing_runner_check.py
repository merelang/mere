#!/usr/bin/env python3
"""Exercise the listing gate with controlled compiler output and worker failures."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

SCRIPT = Path(__file__).with_name("rv_listing_check.sh")
FAKE = r'''#!/usr/bin/env python3
import fcntl
import json
import os
from pathlib import Path
import signal
import struct
import sys
import time

flag, source = sys.argv[1:]
name = Path(source).name
root = Path(__file__).resolve().parents[3]
mode = os.environ.get("LISTING_CONTROL", "healthy")

def event(kind):
    with (root / "events").open("a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        f.write(json.dumps([kind, os.getpid(), flag, name]) + "\n")

event("start")
if os.environ.get("LISTING_BARRIER") and name == "a.mere" and flag in ("-rv", "-rv64"):
    (root / (flag + ".started")).touch()
    deadline = time.monotonic() + 10
    while not all((root / (f + ".started")).exists() for f in ("-rv", "-rv64")):
        if time.monotonic() > deadline:
            raise RuntimeError("workers did not overlap")
        time.sleep(0.005)
event("end")
if name == "refused.mere":
    sys.exit(1)
wide = name == "wide.mere"
if wide:
    text = Path(source).read_text()
    assert text.count("let rec f") == 6000 and "f3000 x" in text
    if mode == "wide-refused":
        sys.exit(1)
target = wide if mode.startswith("wide-") else name == "a.mere"
control = mode.removeprefix("wide-") if target else "healthy"
for prefix, selected in (("rv32-", not flag.startswith("-rv64")),
                         ("rv64-", flag.startswith("-rv64"))):
    if control.startswith(prefix):
        control = control.removeprefix(prefix) if selected else "healthy"
if control == "worker-death" and flag in ("-rv", "-rv64"):
    os.kill(os.getppid(), signal.SIGTERM)
    sys.exit(1)
if flag.endswith("s"):
    if control == "listing-refused":
        sys.exit(1)
    if control != "empty-listing":
        word = "00000000" if control == "wrong-word" else "00000013"
        addr = "8" if control == "wrong-address" else "0"
        print(f"main:\n  {addr}:  {word}  nop\n  4:  00000013  nop")
        if wide and control != "no-wide-jump":
            print("  # auipc+jalr")
elif flag.endswith("g"):
    if control == "map-refused":
        sys.exit(1)
    addr = 4 if control == "wrong-symbol" else 0
    print(f"S {addr} main\nS 4 .local")
else:
    sys.stdout.buffer.write(struct.pack("<II", 19, 19))
'''


def exercise(root, workers, control="healthy"):
    events = root / "events"
    events.write_text("")
    for marker in root.glob("*.started"):
        marker.unlink()
    env = dict(os.environ, LISTING_CONTROL=control, TMPDIR=str(root / "scratch"))
    env.pop("LISTING_BARRIER", None)
    if workers == 2 and control == "healthy":
        env["LISTING_BARRIER"] = "1"
    command = ["sh", str(root / "scripts" / SCRIPT.name)]
    if workers != 2 or control != "healthy":
        command += ["--workers", str(workers)]
    run = subprocess.run(command, env=env, capture_output=True, text=True, timeout=30)
    assert not list((root / "scratch").iterdir()), "temporary files were retained"
    calls = [json.loads(line) for line in events.read_text().splitlines()]
    return run, calls


def main():
    with tempfile.TemporaryDirectory(prefix="rv listing controls ") as directory:
        root = Path(directory)
        (root / "scripts").mkdir()
        (root / "scratch").mkdir()
        shutil.copyfile(SCRIPT, root / "scripts" / SCRIPT.name)
        compiler = root / "_build/default/bin/mere.exe"
        compiler.parent.mkdir(parents=True)
        compiler.write_text(FAKE)
        compiler.chmod(0o755)
        corpus = root / "test/parity"
        corpus.mkdir(parents=True)
        for name in ("a", "b", "refused"):
            (corpus / (name + ".mere")).write_text("print_int 1\n")
        outputs = []
        controls = 0
        for workers in (1, 2):
            run, events = exercise(root, workers)
            assert run.returncode == 0, run.stdout + run.stderr
            assert "5 listings (10 encoded words" in run.stdout and "1 auipc+jalr" in run.stdout
            active = set()
            peak = 0
            calls = []
            for kind, pid, flag, name in events:
                if kind == "start":
                    active.add(pid)
                    peak = max(peak, len(active))
                    calls.append((flag, name))
                else:
                    active.remove(pid)
            assert not active and peak == workers, (workers, peak)
            expected = [(flag + suffix, name + ".mere") for name in ("a", "b")
                        for flag in ("-rv", "-rv64") for suffix in ("", "s", "g")]
            expected += [(flag, "refused.mere") for flag in ("-rv", "-rv64")]
            expected += [(flag, "wide.mere") for flag in ("-rv64", "-rv64s", "-rv64g")]
            assert sorted(calls) == sorted(expected), calls
            outputs.append(run.stdout)
            for control in ("wrong-word", "wrong-address", "wrong-symbol", "empty-listing",
                            "listing-refused", "map-refused", "worker-death", "wide-refused",
                            "wide-wrong-word", "wide-wrong-symbol", "wide-no-wide-jump",
                            "rv32-wrong-word", "rv64-wrong-word",
                            "rv32-worker-death", "rv64-worker-death"):
                run, events = exercise(root, workers, control)
                assert run.returncode != 0, (workers, control, run.stdout)
                assert "ok rv_listing:" not in run.stdout, (control, run.stdout)
                if control == "wrong-word" and workers == 2:
                    assert run.stdout.index("at -rv:") < run.stdout.index("at -rv64:"), run.stdout
                if not control.startswith("wide-"):
                    assert all(event[3] == "a.mere" for event in events), (control, events)
                controls += 1
        assert outputs[0] == outputs[1], outputs
        for invalid in ("0", "3", "bad"):
            run, events = exercise(root, invalid)
            assert run.returncode != 0 and not events
            controls += 1
        print(f"rv_listing_runner_check: identical complete serial/parallel results, at most two workers; {controls} failure controls passed")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Run every normalization case once, preserving corpus order and failures."""
from contextlib import ExitStack
from pathlib import Path
import hashlib
import os
import resource
import signal
import subprocess
import sys
import time


def cpu_limit():
    resource.setrlimit(resource.RLIMIT_CPU, (1800, 1800))


def interrupted(signum, frame):
    raise KeyboardInterrupt


def run(mere, probe, directory, jobs):
    if jobs not in (1, 2):
        raise ValueError("NORMALIZE_JOBS must be 1 or 2")
    corpus = (directory / "corpus.txt").read_bytes().splitlines(keepends=True)
    if not corpus or any(not line.strip() or not line.endswith(b"\n") for line in corpus):
        raise ValueError("empty or malformed normalization corpus")
    slices = [corpus[len(corpus) * i // jobs:len(corpus) * (i + 1) // jobs]
              for i in range(jobs)]
    inputs = [directory / f"corpus-{i}.txt" for i in range(jobs)]
    outputs = [directory / f"ours-{i}.txt" for i in range(jobs)]
    for path, lines in zip(inputs, slices):
        path.write_bytes(b"".join(lines))

    def verify_partition():
        # Read the files actually passed to the interpreters. Exact slices check
        # order and multiplicity even when different cases have identical answers.
        for path, lines in zip(inputs, slices):
            if path.read_bytes() != b"".join(lines):
                raise ValueError("normalization input partition changed")
        if [line for lines in slices for line in lines] != corpus:
            raise ValueError("normalization input partition lost or repeated cases")

    processes = []
    with ExitStack() as files:
        try:
            verify_partition()
            for input_path, output_path in zip(inputs, outputs):
                output = files.enter_context(output_path.open("wb"))
                env = dict(os.environ, NORMALIZE_CORPUS=str(input_path))
                processes.append(subprocess.Popen([str(mere), str(probe)], env=env,
                                                  stdout=output, preexec_fn=cpu_limit))
            deadline = time.monotonic() + 1800
            while True:
                statuses = [process.poll() for process in processes]
                for index, status in enumerate(statuses):
                    if status is not None and status != 0:
                        raise RuntimeError(f"normalization worker {index + 1} exited {status}")
                if all(status is not None for status in statuses):
                    break
                if time.monotonic() >= deadline:
                    raise TimeoutError("normalization workers exceeded 1800 seconds")
                time.sleep(0.05)
        finally:
            # Stop and reap all workers before the shell removes their inputs.
            for process in processes:
                if process.poll() is None:
                    process.terminate()
            for process in processes:
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
    verify_partition()
    ordered = []
    for path, lines in zip(outputs, slices):
        data = path.read_bytes()
        if len(data.splitlines()) != len(lines) or (lines and not data.endswith(b"\n")):
            raise ValueError("normalization worker output has missing or extra cases")
        ordered.append(data)
    data = b"".join(ordered)
    (directory / "ours_raw.txt").write_bytes(data)
    print(f"normalize_workers: {len(corpus)} cases, {jobs} workers, "
          f"ordered output sha256 {hashlib.sha256(data).hexdigest()}")


def main():
    signal.signal(signal.SIGTERM, interrupted)
    try:
        mere, probe, directory, jobs = sys.argv[1:]
        run(mere, probe, Path(directory), int(jobs))
    except (ValueError, RuntimeError, TimeoutError, OSError, KeyboardInterrupt) as error:
        print(f"normalize_workers: FAILED ({error})", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Bound Map storage and prove that restoring either old policy fails the bound."""
from pathlib import Path
import os
import re
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
MERE = Path(os.environ.get("MERE", ROOT / "_build/default/bin/mere.exe"))
CC = shlex.split(os.environ.get("CC", "cc"))

SUFFIX = """
let m = map_new ();
let rec mk = fn (n: int) -> fn (xs: int list) ->
  if n <= 0 then xs else mk (n - 1) (Cons (n, xs));
let _ = map_set m 1 (mk 4000 Nil);
let _ = map_compact m;
let before = map_bytes m;
let rec drain = fn (n: int) ->
  if n <= 0 then () else
    match map_get m 1 with
    | Nil -> ()
    | Cons (_, tail) -> let _ = map_set m 1 tail in drain (n - 1);
let _ = drain 3990;
let _ = print_int before;
let _ = print_int (map_bytes m);
let _ = print_int (list_sum (map_get m 1));
"""

COMPACT = """
let maps = vec_new ();
let rec keep = fn (n: int) -> fn (bytes: int) ->
  if n <= 0 then bytes else
    let m = map_new () in
    let _ = map_set m 1 n in
    let _ = map_compact m in
    let _ = vec_push maps m in
    keep (n - 1) (bytes + map_bytes m);
let bytes = keep 1000 0;
let rec sum = fn (i: int) -> fn (acc: int) ->
  if i >= vec_len maps then acc
  else sum (i + 1) (acc + map_get (vec_get maps i) 1);
let _ = print_int bytes;
let _ = print_int (sum 0 0);
"""


def run(args, cwd):
    result = subprocess.run([str(a) for a in args], cwd=cwd, capture_output=True, timeout=60)
    if result.returncode or result.stderr:
        raise RuntimeError(f"{Path(str(args[0])).name} failed: {result.stderr.decode(errors='replace')[:1000]}")
    return result.stdout


def measure(code, directory):
    (directory / "probe.c").write_bytes(code)
    run([*CC, "-O2", "-w", "probe.c", "-o", "probe", "-lm", "-lpthread"], directory)
    return [int(line) for line in run([directory / "probe"], directory).splitlines()]


def bounded(name, values):
    if name == "suffix":
        before, after, answer = values
        if answer != 39955 or not 64000 <= before <= 1048576 or after < before:
            raise RuntimeError(f"suffix probe lost its values or storage meter: {values}")
        return after <= before * 2 + 4096
    held, answer = values
    # One thousand nonempty maps retain at least one 256-byte block each.
    if answer != 500500 or held < 256000:
        raise RuntimeError(f"compact probe lost its values or storage meter: {values}")
    return held <= 1536000


def main():
    with tempfile.TemporaryDirectory(prefix="map-allocation-") as tmp:
        directory = Path(tmp)
        for name, source in [("suffix", SUFFIX), ("compact", COMPACT)]:
            file = directory / "probe.mere"
            file.write_text(source)
            code = run([MERE, "-c", file], directory)
            values = measure(code, directory)
            if not bounded(name, values):
                raise RuntimeError(f"{name} storage exceeds its bound: {values}")
            if name == "suffix":
                # Restore copying even when the replacement is the existing tail.
                pattern = rb"if \(__o == __mv\) \{ m->values\[i\] = __mv; return 0; \}"
                poisoned, count = re.subn(pattern, b"", code)
            else:
                # Restore the former minimum block size for compacted maps.
                seed = b"size_t __seed = m->live <= 3 ? 256 : 512;"
                poisoned = code.replace(seed, b"size_t __seed = 4096;")
                count = code.count(seed)
            if count != 1:
                raise RuntimeError(f"{name} control lost its single mutation site: {count}")
            old_values = measure(poisoned, directory)
            if bounded(name, old_values):
                raise RuntimeError(f"{name} bound did not detect the restored old policy: {old_values}")
            print(f"map_allocation: {name} passed {values}; old-policy control rejected {old_values}", flush=True)


if __name__ == "__main__":
    main()

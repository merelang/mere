#!/usr/bin/env python3
"""Bound native repeated string-root scans and prove their failure witnesses."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
MERE = os.environ.get("MERE", str(ROOT / "_build/default/bin/mere.exe"))
CC = os.environ.get("CC", "clang")
NATIVE = r'''
#include <sys/resource.h>
void scan_checkpoint(int phase) {
  size_t bytes = 0;
  for (__lang_region_block* b = __lang_blk_tl; b; b = b->gnext) bytes += b->pad;
  for (__lang_region_block* b = __lang_blk_dl; b; b = b->gnext) bytes += b->pad;
  struct rusage r;
  if (getrusage(RUSAGE_SELF, &r)) exit(2);
  unsigned long long rss = (unsigned long long)r.ru_maxrss;
#ifndef __APPLE__
  rss *= 1024;
#endif
  fprintf(stderr, "scan-sample %d %zu %zu %llu\n",
          phase, bytes, __lang_default_region.alloc_total, rss);
}
'''
MODES = {
    "O0": ["-O0"],
    "O2": ["-O2"],
    "sanitized": ["-O1", "-g", "-fsanitize=address,undefined", "-fno-omit-frame-pointer"],
}


class Growth(Exception):
    pass


def compile_program(folder, name, code, mode):
    source = folder / (name + ".c")
    source.write_text(code + NATIVE)
    binary = folder / (name + "-" + mode)
    subprocess.run([CC, *MODES[mode], "-w", str(source), "-lm", "-lpthread", "-o", str(binary)],
                   check=True, timeout=90)
    return binary


def execute(binary, rounds, candidates):
    # ASan's allocator quarantine is not the language's retention policy.
    # Apply region/default-arena bounds in all modes, and RSS only under O2.
    env = dict(os.environ, ASAN_OPTIONS="detect_leaks=0", UBSAN_OPTIONS="halt_on_error=1")
    start = time.monotonic()
    result = subprocess.run([str(binary), str(rounds), str(candidates)], env=env,
                            capture_output=True, text=True, timeout=90)
    return result, time.monotonic() - start


def measurements(result, rounds):
    if result.returncode != 0 or result.stdout != "scan stability passed\n":
        raise AssertionError((result.returncode, result.stdout, result.stderr))
    rows = [tuple(map(int, m)) for m in re.findall(
        r"^scan-sample (\d+) (\d+) (\d+) (\d+)$", result.stderr, re.M)]
    if (len(rows) != 2 or [r[0] for r in rows] != [15, rounds - 1]
            or any(r[1] <= 0 or r[3] <= 0 for r in rows)):
        raise AssertionError(("missing native measurements", result.stderr))
    return rows


def check_growth(rows):
    warm, final = rows
    # Wide slack permits region/block cache warmup while catching linear
    # retention. Default-arena allocation is cumulative; named regions reset.
    if final[2] > warm[2] + 65536:
        raise Growth("default arena grew")
    if final[1] > warm[1] + 2 * 1024 * 1024:
        raise Growth("live region capacity grew")


def mutations(code):
    start = code.index("static void __lang_coro_scan_strings(")
    end = code.index("\nstatic void __lang_coro_swap(", start)
    api = code[start:end]
    assert api.count("__lang_current_region") == 3
    release = "static void __lang_region_block_release(__lang_region* r) {"
    found = "e->found = 1;"
    stopped = "from->x->sep = __lang_region_epoch; from->x->pgot = 0;"
    resumed = "to->x->pgot = 0; to->x->sgot = 0;"
    for marker in [release, found, stopped, resumed]:
        assert code.count(marker) == 1, ("native shape changed", marker)
    return [
        ("scan-storage", "default arena grew", code[:start] + api.replace(
            "__lang_current_region", "&__lang_default_region") + code[end:]),
        ("scratch-release", "live region capacity grew", code.replace(release, release +
            '\n  if (r && r->site && strcmp(r->site, "region Scratch") == 0) return;')),
        ("root-match", "root", code.replace(found, "e->found = 0;")),
        ("pin-cache", "root", code.replace(stopped, "from->x->sep = __lang_region_epoch;").replace(
            resumed, "to->x->sgot = 0;")),
    ]


def main():
    emitted = subprocess.run([MERE, "-c", str(ROOT / "test/coro/scan_strings_repeated.mere")],
                             stdout=subprocess.PIPE, text=True, check=True, timeout=90).stdout
    with tempfile.TemporaryDirectory(prefix="mere-scan-stability-") as directory:
        folder = Path(directory)
        for mode in MODES:
            binary = compile_program(folder, "healthy", emitted, mode)
            for candidates in [1000, 4000]:
                runs = []
                for rounds in [32, 256]:
                    result, seconds = execute(binary, rounds, candidates)
                    rows = measurements(result, rounds)
                    check_growth(rows)
                    runs.append(rows[-1])
                    print(f"scan stability {mode}: candidates={candidates} rounds={rounds} "
                          f"region_bytes={rows[-1][1]} default_alloc={rows[-1][2]} "
                          f"rss_bytes={rows[-1][3]} seconds={seconds:.3f}", flush=True)
                if mode == "O2" and runs[1][3] > runs[0][3] * 2 + 8 * 1024 * 1024:
                    raise Growth("RSS follows iteration count")
        for name, witness, changed in mutations(emitted):
            for mode in ["O2", "sanitized"]:
                binary = compile_program(folder, name, changed, mode)
                result, _ = execute(binary, 64, 1000)
                if witness == "root":
                    assert result.returncode == 1 and "fail: scan stability: live root missing" in result.stderr, (
                        name, mode, result.returncode, result.stdout, result.stderr)
                    assert "ERROR: AddressSanitizer" not in result.stderr and "runtime error:" not in result.stderr
                else:
                    rows = measurements(result, 64)
                    try:
                        check_growth(rows)
                    except Growth as error:
                        assert str(error) == witness, (name, mode, error)
                    else:
                        raise AssertionError(("negative control stayed green", name, mode))
                print(f"scan stability control caught: {name} {mode} ({witness})", flush=True)
    print("scan stability: 12 positive runs and 8 negative controls passed", flush=True)


if __name__ == "__main__":
    main()

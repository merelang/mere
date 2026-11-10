#!/usr/bin/env python3
"""Measure native candidate indexing and root discovery separately."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
NATIVE = r'''
#include <time.h>
#include <sys/resource.h>
static unsigned long long bench_ticks[5], bench_ns[4];
static unsigned long long bench_calls, bench_probes, bench_words, bench_bytes;
static unsigned long long bench_begin, bench_total;
#ifdef MERE_SCAN_VERIFY
static void bench_oracle(void);
#endif
static unsigned long long bench_clock(void) {
  struct timespec t;
  if (clock_gettime(CLOCK_MONOTONIC, &t)) exit(2);
  return (unsigned long long)t.tv_sec * 1000000000ULL + t.tv_nsec;
}
static void bench_phase(int phase) {
  bench_ticks[phase] = bench_clock();
  if (phase) bench_ns[phase - 1] += bench_ticks[phase] - bench_ticks[phase - 1];
  if (phase == 4) bench_calls++;
}
void scan_bench_reset(void) {
#ifdef MERE_SCAN_VERIFY
  bench_oracle();
#endif
  memset(bench_ns, 0, sizeof bench_ns);
  bench_calls = bench_probes = bench_words = bench_bytes = 0;
  bench_total = 0;
}
void scan_bench_begin(void) { bench_begin = bench_clock(); }
void scan_bench_end(void) { bench_total += bench_clock() - bench_begin; }
void scan_bench_report(int expected) {
  if (bench_calls != (unsigned long long)expected) exit(3);
  struct rusage r;
  if (getrusage(RUSAGE_SELF, &r)) exit(2);
  unsigned long long rss = (unsigned long long)r.ru_maxrss;
#ifndef __APPLE__
  rss *= 1024;
#endif
  fprintf(stderr, "{\"calls\":%llu,\"index_ns\":%llu,\"pin_ns\":%llu,"
          "\"search_ns\":%llu,\"callback_ns\":%llu,\"header_probes\":%llu,"
          "\"pin_words\":%llu,\"candidate_bytes\":%llu,\"rss_bytes\":%llu,\"total_ns\":%llu}\n",
          bench_calls, bench_ns[0], bench_ns[1], bench_ns[2], bench_ns[3],
          bench_probes, bench_words, bench_bytes, rss, bench_total);
}
'''


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(("native instrumentation marker changed", old, text.count(old)))
    return text.replace(old, new)


def instrument(source):
    start = source.index("typedef struct { const char* text; size_t len, next;")
    end = source.index("\nstatic void __lang_coro_swap(", start)
    api = source[start:end]
    api = replace_once(api, "  __lang_string_scan s;", "  bench_phase(0);\n  __lang_string_scan s;")
    api = replace_once(api, "    e->len = __lang_str_size(names[i]);",
                       "    e->len = __lang_str_size(names[i]); bench_bytes += e->len;")
    api = replace_once(api, "  if (c != __lang_coro_cur) {",
                       "  bench_phase(1);\n  if (c != __lang_coro_cur) {")
    marker = "    __lang_scan_spans(); s.spans = __lang_scan_sp; s.nsp = __lang_scan_nsp;"
    api = replace_once(api, marker, marker + "\n    bench_phase(2);")
    marker = "  int (*f)(void*, const char*) = (int (*)(void*, const char*))fn;"
    api = replace_once(api, marker, "  bench_phase(3);\n" + marker)
    marker = "  for (size_t i = 0; i < n; i++) if (s.entries[i].found) f(env, s.entries[i].text);"
    api = replace_once(api, marker, marker + "\n  bench_phase(4);")
    marker = "  uintptr_t a = w & ~(uintptr_t)7;"
    api = replace_once(api, marker, "  bench_words++;\n" + marker)
    marker = "  for (uintptr_t p = begin; p <= end; p += 8) {"
    api = replace_once(api, marker,
                       "  if (begin <= end) bench_probes += (end - begin) / 8 + 1;\n" + marker)
    return source[:start] + NATIVE + api + source[end:]


def compile_native(cc, folder, name, code, flags):
    source, binary = folder / (name + ".c"), folder / name
    source.write_text(code)
    subprocess.run([cc, *flags, "-w", str(source), "-lm", "-lpthread", "-o", str(binary)],
                   check=True, timeout=90)
    return binary


def execute(binary, count, width, workers, rounds):
    env = dict(os.environ, ASAN_OPTIONS="detect_leaks=0", UBSAN_OPTIONS="halt_on_error=1")
    return subprocess.run([str(binary), str(count), str(width), str(workers), str(rounds)],
                          env=env, text=True, capture_output=True, timeout=90)


def measured(run, calls):
    if run.returncode or run.stdout != "scan benchmark passed\n":
        raise AssertionError((run.returncode, run.stdout, run.stderr))
    sample = json.loads(run.stderr)
    if sample["calls"] != calls or min(sample.values()) <= 0:
        raise AssertionError(sample)
    return sample


def verify_controls(cc, folder, code):
    profiles = {
        "O2": ["-O2", "-DMERE_SCAN_VERIFY"],
        "sanitized": ["-O1", "-g", "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                      "-DMERE_SCAN_VERIFY"],
    }
    changed = [
        ("overlap", 5, "scan oracle: repeated header visits", replace_once(
            code, "s->scanned = end & ~(uintptr_t)7;", "s->scanned = 0;")),
        ("skip-header", 4, "scan oracle: match mismatch", replace_once(
            code, "begin = s->scanned + 8;", "begin = s->scanned + 16;")),
    ]
    binary = compile_native(cc, folder, "sanitized", code, profiles["sanitized"])
    for count, width, workers in CASES:
        measured(execute(binary, count, width, workers, 8), workers * 8)
        print(f"scan scaling sanitized passed: candidates={count} width={width} coroutines={workers}",
              flush=True)
    for mode, flags in profiles.items():
        for name, status, witness, mutation in changed:
            binary = compile_native(cc, folder, name + "-" + mode, mutation, flags)
            run = execute(binary, 256, 16, 1, 8)
            if (run.returncode != status or witness not in run.stderr
                    or "ERROR: AddressSanitizer" in run.stderr or "runtime error:" in run.stderr):
                raise AssertionError((name, mode, run.returncode, run.stdout, run.stderr))
            print(f"scan scaling control caught: {name} {mode} ({witness})", flush=True)
    print("scan scaling: 18 workloads, 1136 reference cases per execution and 4 controls passed", flush=True)


CASES = [(256, 16, 1), (1024, 16, 1), (4096, 16, 1),
         (1024, 256, 1), (1024, 4096, 1), (1024, 32768, 1),
         (1024, 16, 8), (1024, 16, 32), (1024, 32768, 8)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mere", default=os.environ.get("MERE", str(ROOT / "_build/default/bin/mere.exe")))
    parser.add_argument("--reps", type=int, default=5)
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--output", type=Path)
    options = parser.parse_args()
    if options.reps < 1:
        parser.error("--reps must be positive")
    cc = os.environ.get("CC", "clang")
    emitted = subprocess.check_output([options.mere, "-c", str(Path(__file__).with_name("bench.mere"))],
                                      text=True, timeout=90)
    record = {"system": platform.platform(),
              "compiler": subprocess.check_output([cc, "--version"], text=True).splitlines()[0],
              "mere": subprocess.check_output([options.mere, "--version"], text=True).strip(),
              "emitted_c_sha256": hashlib.sha256(emitted.encode()).hexdigest(),
              "flags": ["-O2"], "cases": []}
    print(record["system"], record["compiler"], record["mere"], flush=True)
    with tempfile.TemporaryDirectory(prefix="mere-scan-bench-") as directory:
        folder = Path(directory)
        code = instrument(emitted)
        flags = ["-O2"]
        if options.verify_only:
            code += Path(__file__).with_name("oracle.c").read_text()
            flags += ["-DMERE_SCAN_VERIFY"]
        binary = compile_native(cc, folder, "bench", code, flags)
        rounds = 8 if options.verify_only else 32
        for count, width, workers in CASES:
            samples = []
            for _ in range(1 if options.verify_only else options.reps):
                samples.append(measured(execute(binary, count, width, workers, rounds), workers * rounds))
            row = {"unused_candidates": count, "long_candidate_bytes": width,
                   "coroutines": workers, "rounds": rounds, "samples": samples}
            record["cases"].append(row)
            fields = []
            for key in ["total_ns", "index_ns", "pin_ns", "search_ns", "callback_ns"]:
                values = [s[key] / s["calls"] / 1000 for s in samples]
                fields.append(f"{key.removesuffix('_ns')}={statistics.median(values):.2f}us"
                              f"[{min(values):.2f},{max(values):.2f}]")
            print(f"candidates={count}+65 width={width} coroutines={workers}: " + " ".join(fields)
                  + f" probes/scan={samples[0]['header_probes'] // samples[0]['calls']}"
                  + f" rss=[{min(s['rss_bytes'] for s in samples)},{max(s['rss_bytes'] for s in samples)}]",
                  flush=True)
        if options.verify_only:
            verify_controls(cc, folder, code)
    if options.output:
        options.output.write_text(json.dumps(record, indent=2) + "\n")


if __name__ == "__main__":
    main()

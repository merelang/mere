#!/usr/bin/env python3
"""Native empty-map lifecycle and initial-storage allocation regression."""
import os
from pathlib import Path
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parent.parent
MERE = os.environ.get("MERE", str(ROOT / "_build/default/bin/mere.exe"))
SOURCE = r'''extern fn test_usage: unit -> int;
let before = test_usage ();
let m = map_new ();
let _ = print_bool (test_usage () - before < 160);
let _ = print_int (map_len m);
let _ = print_bool (map_has m "missing");
let _ = print_int (try_or (fn (_u: unit) -> map_get m "missing") 42);
let _ = map_delete m "missing";
let _ = map_clear m;
let _ = print_bool (map_len m == 0);
let _ = map_set m "a" 1;
let _ = map_set m "b" 2;
let _ = map_delete m "a";
let _ = print_int (map_get m "b");
let _ = map_clear m;
let _ = map_set m "again" 3;
let _ = print_int (map_get m "again");
let _ = map_recycle m;
let _ = print_int (map_len m);
let _ = print_bool (map_has m "again");
let _ = map_set m "recycled" 4;
let _ = map_compact m;
let _ = print_int (map_get m "recycled");
let n = map_new ();
let _ = map_compact n;
let _ = print_int (map_len n);
let _ = map_set n "first" 5;
let _ = print_int (map_get n "first");
let p = map_new ();
let _ = map_recycle p;
let _ = map_set p "first" 6;
let _ = print_int (map_get p "first");
let ints = map_new ();
let _ = map_delete ints 10;
let _ = print_bool (map_has ints 10);
let _ = map_set ints 10 "ten";
let _ = print (map_get ints 10);
let _ = map_delete ints 10;
let _ = print_bool (map_has ints 10);
let _ = map_set ints 11 "eleven";
let _ = map_compact ints;
let _ = print (map_get ints 11);
'''
NATIVE = r'''
int test_usage(void) { return (int)__lang_default_region.alloc_total; }

'''
EXPECTED = b"true\n0\nfalse\n42\ntrue\n2\n3\n0\nfalse\n4\n0\n5\n6\nfalse\nten\nfalse\neleven\n"
with tempfile.TemporaryDirectory(prefix="mere-empty-map-") as folder:
    folder = Path(folder)
    program = folder / "main.mere"
    program.write_text(SOURCE)
    result = subprocess.run([MERE, "-c", str(program)], capture_output=True)
    assert result.returncode == 0, result.stderr.decode()
    c = result.stdout.decode()
    cfile = folder / "main.c"
    cfile.write_text(c + NATIVE)
    for mode, flags in [("O2", ["-O2"]), ("ASan", ["-O1", "-fsanitize=address", "-fno-omit-frame-pointer"])]:
        binary = folder / mode
        subprocess.run(["clang", *flags, "-w", "-fbracket-depth=1024", str(cfile), "-lm", "-o", str(binary)], check=True)
        result = subprocess.run([str(binary)], check=True, capture_output=True, timeout=30,
            env=dict(os.environ, ASAN_OPTIONS="detect_leaks=0"))
        assert result.stdout == EXPECTED, (mode, result.stdout, result.stderr)
print("Empty maps: lazy storage, missing keys, mutation, clear, recycle and compact (O2/ASan)")

# Exhaust the map's home arena and fail exactly one OS allocation. The remaining
# 0/32/64/72 bytes put the failure in keys/values/tombstones/index respectively.
RETRY_SOURCE = r'''extern fn test_arm: unit -> unit;
extern fn test_disarm: unit -> unit;
let m = map_new ();
let caught = try_or (fn (_u: unit) ->
  let _ = test_arm () in let _ = map_set m 1 7 in true) false;
let _ = test_disarm ();
let _ = print_bool caught;
let _ = print_int (map_len m);
let _ = print_bool (map_has m 1);
let _ = map_set m 2 8;
let _ = print_int (map_get m 2);
let _ = print_int (map_len m);
let _ = map_compact m;
let _ = print_int (map_get m 2);
'''
RETRY_PREFIX = r'''
#include <stdlib.h>
#include <stddef.h>
#include <sys/mman.h>
#include <errno.h>
static void* test_malloc(size_t);
static void* test_mmap(void*, size_t, int, int, int, off_t);
#define malloc test_malloc
#define mmap test_mmap
'''
RETRY_NATIVE = r'''
#undef malloc
#undef mmap
static int test_fail_next;
static void* test_malloc(size_t n) {
  if (test_fail_next) { test_fail_next = 0; return NULL; }
  return malloc(n);
}
static void* test_mmap(void* addr, size_t n, int prot, int flags,
                       int fd, off_t offset) {
  if (test_fail_next) {
    test_fail_next = 0; errno = ENOMEM; return MAP_FAILED;
  }
  return mmap(addr, n, prot, flags, fd, offset);
}
void test_arm(void) {
  __lang_region* r = &__lang_default_region;
  size_t room = (size_t)strtoul(getenv("MERE_TEST_ROOM"), NULL, 10);
  size_t available = (size_t)(r->base + r->cap - r->top);
  if (available <= room) abort();
  (void)__lang_region_alloc(r, available - room);
  test_fail_next = 1;
}
void test_disarm(void) {
  /* A passing run must actually consume the injected allocation failure. */
  if (test_fail_next) abort();
}
'''
with tempfile.TemporaryDirectory(prefix="mere-map-retry-") as folder:
    folder = Path(folder)
    program = folder / "retry.mere"
    program.write_text(RETRY_SOURCE)
    result = subprocess.run([MERE, "-c", str(program)], capture_output=True, check=True)
    cfile = folder / "retry.c"
    cfile.write_text(RETRY_PREFIX + result.stdout.decode() + RETRY_NATIVE)
    for mode, flags in [("O2", ["-O2"]), ("ASanUBSan", ["-O1", "-g",
            "-fsanitize=address,undefined", "-fno-sanitize-recover=all",
            "-fno-omit-frame-pointer"])]:
        binary = folder / mode
        subprocess.run(["clang", *flags, "-w", "-fbracket-depth=1024",
            str(cfile), "-lm", "-pthread", "-o", str(binary)], check=True)
        for room in [0, 32, 64, 72]:
            result = subprocess.run([str(binary)], capture_output=True, timeout=30,
                env=dict(os.environ, MERE_TEST_ROOM=str(room), ASAN_OPTIONS="detect_leaks=0"))
            assert result.returncode == 0 and result.stdout == b"false\n0\nfalse\n8\n1\n8\n", (
                mode, room, result.returncode, result.stdout, result.stderr)
print("Map allocation failure: four stages, retry and compact (O2/ASan/UBSan)")

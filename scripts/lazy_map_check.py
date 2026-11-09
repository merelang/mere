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

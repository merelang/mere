#!/usr/bin/env python3
"""Native compact-map slack and subsequent growth/recycle regression."""
import os
from pathlib import Path
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parent.parent
MERE = os.environ.get("MERE", str(ROOT / "_build/default/bin/mere.exe"))
SOURCE = r'''type Value = Number of int | Flag of bool | Object of int;
let m = map_new ();
let _ = map_recycle m;
let _ = map_set m "__eid" (Number 42);
let _ = map_set m "__captured" (Flag true);
let _ = map_set m "o" (Object 99);
let _ = map_compact m;
let _ = print_bool (map_bytes m <= 256);
let _ = print_bool (map_get m "__eid" == Number 42);
let _ = print_bool (map_get m "o" == Object 99);
let _ = map_set m "large" (Object 123);
let rec grow = fn (i: int) ->
  if i == 1000 then () else (let _ = map_set m (str_of_int i) (Number i) in grow (i + 1));
let _ = grow 0;
let _ = map_compact m;
let _ = print_bool (map_get m "999" == Number 999);
let _ = print_bool (map_get m "__captured" == Flag true);
let _ = map_recycle m;
let _ = print_bool (map_len m == 0);
let _ = map_set m "again" (Number 7);
let _ = map_compact m;
let _ = print_bool (map_get m "again" == Number 7);
let big = map_new ();
let _ = map_set big "x" (str_repeat "large payload" 1000);
let _ = map_compact big;
let _ = print_bool (str_len (map_get big "x") == 13000);
let _ = map_set big "x" "small";
let _ = map_compact big;
let _ = print_bool (str_eq (map_get big "x") "small");
'''
EXPECTED = b"true\n" * 9
with tempfile.TemporaryDirectory(prefix="mere-small-map-") as folder:
    folder = Path(folder)
    program = folder / "main.mere"
    program.write_text(SOURCE)
    result = subprocess.run([MERE, "-c", str(program)], capture_output=True)
    assert result.returncode == 0, result.stderr.decode()
    c = result.stdout.decode()
    cfile = folder / "main.c"
    cfile.write_text(c)
    for mode, flags in [("O2", ["-O2"]), ("ASan", ["-O1", "-fsanitize=address", "-fno-omit-frame-pointer"])]:
        binary = folder / mode
        subprocess.run(["clang", *flags, "-w", "-fbracket-depth=1024", str(cfile), "-lm", "-o", str(binary)], check=True)
        result = subprocess.run([str(binary)], check=True, capture_output=True, timeout=30,
            env=dict(os.environ, ASAN_OPTIONS="detect_leaks=0"))
        assert result.stdout == EXPECTED, (mode, result.stdout, result.stderr)
print("Small compacted maps: bounded slack, values, growth, recycle and large payloads (O2/ASan)")

#!/usr/bin/env python3
"""Joined strings retain ownership without a full-sized temporary copy."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
MERE = os.environ.get('MERE', str(ROOT / '_build/default/bin/mere.exe'))
SOURCE = r'''extern fn allocated: unit -> int;
let v = vec_new ();
let _ = vec_compact v;
let _ = region R {
  let chunk = str_repeat "x" 65536 in
  let rec parts = fn n -> fn xs -> if n == 0 then xs else parts (n - 1) (Cons (chunk, xs)) in
  let xs = parts 256 Nil in
  let before = allocated () in
  let _ = vec_push v (str_join "" xs) in
  print_bool (allocated () - before < 65536)
};
let _ = print_bool (str_len (vec_get v 0) == 16777216);
let _ = region R {
  let s = "a" ++ chr 0 ++ "b" in
  let _ = vec_push v (str_join ":" (Cons (s, Cons ("tail", Nil)))) in
  let _ = vec_push v (str_join "ignored" Nil) in
  let _ = vec_push v (str_join "" (Cons (s, Nil))) in
  vec_push v (str_join "!" (Cons (vec_get v 1, Cons ("z", Nil))))
};
let _ = vec_compact v;
let _ = print_bool (str_len (vec_get v 1) == 8);
let _ = print_bool (ord (char_at (vec_get v 1) 1) == 0);
let _ = print_bool (vec_get v 2 == "");
let _ = print_bool (str_len (vec_get v 3) == 3);
let _ = print_bool (str_len (vec_get v 4) == 10);
let _ = vec_set v 0 "replaced";
let _ = vec_compact v;
let _ = print_bool (vec_get v 1 == "a" ++ chr 0 ++ "b:tail");
let _ = vec_recycle v;
let _ = vec_push v (str_join "-" (Cons ("new", Cons ("value", Nil))));
let _ = print_bool (vec_get v 0 == "new-value");
'''
NATIVE = "\nint allocated(void) { return (int)__lang_current_region->alloc_total; }\n"
with tempfile.TemporaryDirectory(prefix='mere-strvec-join-') as directory:
    folder = Path(directory)
    program = folder / 'check.mere'
    program.write_text(SOURCE)
    c = subprocess.run([MERE, '-c', str(program)], capture_output=True, check=True).stdout.decode()
    (folder / 'check.c').write_text(c + NATIVE)
    for mode, flags in [('O2', ['-O2']), ('asan', ['-O1', '-fsanitize=address', '-fno-omit-frame-pointer'])]:
        binary = folder / mode
        subprocess.run(['clang', *flags, '-w', '-fbracket-depth=1024', str(folder / 'check.c'), '-lm', '-o', str(binary)], check=True)
        result = subprocess.run([str(binary)], capture_output=True, check=True,
                                env=dict(os.environ, ASAN_OPTIONS='detect_leaks=0'), timeout=30)
        assert result.stdout == b'true\n' * 9, result.stdout
print('String Vec join: bounded scratch, NUL bytes, growth, compaction and recycling (O2/ASan)')

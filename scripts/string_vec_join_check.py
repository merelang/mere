#!/usr/bin/env python3
"""Joined strings retain ownership without a full-sized temporary copy."""
import os
from pathlib import Path
import subprocess
import shutil
import sys
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
ORDER = r'''let v = vec_new ();
let _ = vec_compact v;
let shared = str_join ":" (Cons ("a", Cons ("b", Nil)));
let _ = vec_push v shared;
let _ = print_bool (shared == "a:b");
let order = vec_new ();
let target = fn () -> let _ = vec_push order 1 in v;
let separator = fn () -> let _ = vec_push order 2 in "-";
let values = fn () -> let _ = vec_push order 3 in Cons ("x", Cons ("y", Nil));
let _ = vec_push (target ()) (str_join (separator ()) (values ()));
let _ = print_bool (vec_get v 1 == "x-y");
let _ = print_int (vec_get order 0);
let _ = print_int (vec_get order 1);
let _ = print_int (vec_get order 2);
'''
VALUE_ORDER = r'''let v = vec_new ();
let state = vec_new ();
let _ = vec_push state "before";
let separator = fn () -> let _ = vec_set state 0 "after" in ":";
let values = fn () -> [vec_get state 0, "tail"];
let _ = vec_push v (str_join (separator ()) (values ()));
print (vec_get v 0)
'''
SHADOW_JOIN = r'''let v = vec_new ();
let _ = (let str_join = fn (_sep: str) -> fn (_xs: str list) -> "shadowed" in
  let _ = vec_push v (str_join "" (Cons ("original", Nil))) in
  print_bool (vec_get v 0 == "shadowed"));
'''
SHADOW_PUSH = r'''let v = vec_new ();
let _ = (let vec_push = fn (_v: Vec['r, str]) -> fn (_s: str) -> () in
  let _ = vec_push v (str_join "" (Cons ("not stored", Nil))) in
  print_bool (vec_len v == 0));
'''
NATIVE = "\nint allocated(void) { return (int)__lang_current_region->alloc_total; }\n"
compilers = [('clang-O2', 'clang', ['-O2', '-fbracket-depth=1024']),
             ('clang-asan', 'clang', ['-O1', '-fsanitize=address', '-fno-omit-frame-pointer', '-fbracket-depth=1024'])]
gcc = shutil.which('gcc')
if gcc and 'clang' not in subprocess.check_output([gcc, '--version'], text=True).lower():
    compilers.append(('gcc-O2', gcc, ['-O2']))
elif sys.platform.startswith('linux'):
    raise SystemExit('GCC is required on Linux to verify C argument sequencing')
with tempfile.TemporaryDirectory(prefix='mere-strvec-join-') as directory:
    folder = Path(directory)
    for name, source, expected in [('alloc', SOURCE, b'true\n' * 9), ('order', ORDER, b'true\n' * 2 + b'1\n2\n3\n'), ('value_order', VALUE_ORDER, b'after:tail\n'), ('shadow_join', SHADOW_JOIN, b'true\n'), ('shadow_push', SHADOW_PUSH, b'true\n')]:
        program = folder / (name + '.mere')
        program.write_text(source)
        emitted = subprocess.run([MERE, '-c', str(program)], capture_output=True, check=True)
        cfile = folder / (name + '.c')
        cfile.write_text(emitted.stdout.decode() + NATIVE)
        for mode, compiler, flags in compilers:
            binary = folder / (name + mode)
            subprocess.run([compiler, *flags, '-w', str(cfile), '-lm', '-o', str(binary)], check=True)
            result = subprocess.run([str(binary)], capture_output=True, check=False,
                                    env=dict(os.environ, ASAN_OPTIONS='detect_leaks=0'), timeout=30)
            assert result.returncode == 0 and result.stdout == expected, (name, mode, result.returncode, result.stdout, result.stderr)
print('String Vec join: bounded scratch, ownership, shadowing and evaluation order (' + ', '.join(mode for mode, _, _ in compilers) + ')')

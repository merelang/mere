#!/usr/bin/env python3
"""Exercise native string-Vec compaction, including deferred pins and writes."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
MERE = os.environ.get('MERE', str(ROOT / '_build/default/bin/mere.exe'))
SOURCE = '''
extern fn test_copies: unit -> int;
extern fn test_pin: int -> unit;
let v = vec_new ();
let _ = vec_push v "kept";
let _ = vec_compact v;
let _ = print_int (test_copies ());
let _ = vec_compact v;
let _ = vec_compact v;
let _ = print_int (test_copies ());
let _ = vec_set v 0 "changed";
let _ = vec_compact v;
let _ = print_int (test_copies ());
let _ = vec_set v 0 (str_repeat "x" 8388608);
let _ = vec_set v 0 "kept";
let before = vec_bytes v;
let _ = test_pin 1;
let _ = vec_compact v;
let _ = vec_compact v;
let _ = print_int (test_copies ());
let _ = print_bool (vec_bytes v == before);
let _ = test_pin 0;
let _ = vec_compact v;
let _ = print_int (test_copies ());
let _ = print_bool (vec_bytes v == 4096);
let _ = print_bool (vec_get v 0 == "kept");
let _ = vec_compact v;
let _ = print_int (test_copies ());
let _ = vec_recycle v;
let _ = vec_push v "again";
let _ = vec_compact v;
let _ = print_int (test_copies ());
let rec rewrite = fn (i: int) ->
  if i >= vec_len v then () else (let _ = vec_set v i "rewritten" in rewrite (i + 1));
let _ = rewrite 0;
let _ = vec_compact v;
let _ = print_int (test_copies ());
let _ = print_bool (vec_get v 0 == "rewritten");
'''
NATIVE = '''
static int test_forced_pin(__lang_region *r, int growth) { (void)r; (void)growth; return 1; }
void test_pin(int enabled) { __lang_region_pinned = enabled ? test_forced_pin : 0; }
int test_copies(void) { return test_copy_count; }
'''
DERIVED = """
let v = vec_new ();
let _ = vec_push v (str_repeat "x" 1048576);
let _ = vec_compact v;
let base = vec_bytes v;
let rec run = fn (n: int) ->
  if n == 0 then () else
    (let _ = print_int (vec_len (vec_map v (fn (s: str) -> s))) in
     let _ = vec_compact v in
     let _ = print_bool (vec_bytes v == base) in
     let _ = print_int (vec_len (vec_filter v (fn (_s: str) -> true))) in
     let _ = vec_compact v in
     let _ = print_bool (vec_bytes v == base) in
     let _ = print_int (vec_len (vec_concat v v)) in
     let _ = vec_compact v in
     let _ = print_bool (vec_bytes v == base) in
     run (n - 1));
let _ = run 3;
"""
RETIRED = """
extern fn test_retired: unit -> int;
let root = coro_root ();
let v = vec_new ();
let _ = vec_push v (str_repeat "x" 128);
let _ = vec_compact v;
let c = coro_new (fn _me -> fn (_u: unit) ->
  let held = vec_get v 0 in
  let _ = coro_switch root in
  let _ = print_bool (str_len held == 128 && char_at held 0 == "x") in
  coro_exit root ());
let _ = coro_switch c;
let _ = vec_set v 0 "changed";
let _ = vec_compact v;
let _ = vec_set v 0 (str_repeat "y" 2097152);
let _ = vec_set v 0 "kept";
let _ = vec_compact v;
let _ = print_bool (test_retired () > 0);
let _ = coro_switch c;
let _ = vec_compact v;
let _ = print_int (test_retired ());
let _ = print_bool (vec_get v 0 == "kept");
"""
cases = [
    ('writes', SOURCE, b'1\n1\n2\n2\ntrue\n3\ntrue\ntrue\n3\n4\n5\ntrue\n'),
    ('derived', DERIVED, b'1\ntrue\n1\ntrue\n2\ntrue\n' * 3),
    ('retired', RETIRED, b'true\ntrue\n0\ntrue\n'),
]
with tempfile.TemporaryDirectory(prefix='mere-strvec-') as directory:
    folder = Path(directory)
    for name, source, expected in cases:
        program = folder / (name + '.mere')
        program.write_text(source)
        c = subprocess.run([MERE, '-c', str(program)], capture_output=True, check=True).stdout.decode()
        assert c.count('v->compact_dirty = 0;') == 1
        c = c.replace('typedef struct mere_vec_str {', 'static int test_copy_count;\ntypedef struct mere_vec_str {')
        c = c.replace('v->compact_dirty = 0;', 'v->compact_dirty = 0; test_copy_count++;')
        cfile = folder / (name + '.c')
        cfile.write_text(c + NATIVE + '\nint test_retired(void) { return __lang_retired_n; }\n')
        for mode, flags in [('O2', ['-O2']), ('asan', ['-O1', '-fsanitize=address', '-fno-omit-frame-pointer'])]:
            binary = folder / (name + '-' + mode)
            subprocess.run(['clang', *flags, '-w', '-fbracket-depth=1024', str(cfile), '-lm', '-o', str(binary)], check=True)
            result = subprocess.run([str(binary)], capture_output=True, check=True,
                                    env=dict(os.environ, ASAN_OPTIONS='detect_leaks=0'), timeout=30)
            assert result.stdout == expected, (name, mode, result.stdout, result.stderr)
print('String Vec compaction: unchanged pages, writes, derived arenas, deferred pins and retired arenas (O2/ASan)')

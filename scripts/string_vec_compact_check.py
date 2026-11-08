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
with tempfile.TemporaryDirectory(prefix='mere-strvec-') as directory:
    folder = Path(directory)
    program = folder / 'check.mere'
    program.write_text(SOURCE)
    c = subprocess.run([MERE, '-c', str(program)], capture_output=True, check=True).stdout.decode()
    # Count actual successful arena swaps, not vec_compact calls.
    assert c.count('v->compact_dirty = 0;') == 1
    c = c.replace('typedef struct mere_vec_str {', 'static int test_copy_count;\ntypedef struct mere_vec_str {')
    c = c.replace('v->compact_dirty = 0;', 'v->compact_dirty = 0; test_copy_count++;')
    (folder / 'check.c').write_text(c + NATIVE)
    for mode, flags in [('O2', ['-O2']), ('asan', ['-O1', '-fsanitize=address', '-fno-omit-frame-pointer'])]:
        binary = folder / mode
        subprocess.run(['clang', *flags, '-w', '-fbracket-depth=1024', str(folder / 'check.c'), '-lm', '-o', str(binary)], check=True)
        result = subprocess.run([str(binary)], capture_output=True, check=True,
                                env=dict(os.environ, ASAN_OPTIONS='detect_leaks=0'), timeout=30)
        assert result.stdout == b'1\n1\n2\n2\ntrue\n3\ntrue\ntrue\n3\n4\n5\ntrue\n', result.stdout
print('String Vec compaction: unchanged pages skipped; writes and deferred pins retried (O2/ASan)')

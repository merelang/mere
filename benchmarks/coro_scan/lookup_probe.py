#!/usr/bin/env python3
"""Instrument emitted C for the single-evaluator Enumerator workload only.

Usage: lookup_probe.py input.c output.c
Counter instrumentation is diagnostic; use uninstrumented binaries for timings.
"""
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_bytes()
def replace(old, new):
    global source
    old, new = old.encode(), new.encode()
    assert source.count(old) == 1, ('probe marker must match once', old)
    source = source.replace(old, new)

marker = '#define __LANG_SCAN_FOREIGN_HOPS 3'
replace(marker, '''static unsigned long long __lang_lookup_probe[8];
__attribute__((destructor)) static void __lang_lookup_report(void) {
  fprintf(stderr, "lookup-probe words=%llu eligible=%llu binary=%llu gaps=%llu cache_hits=%llu cache_gaps=%llu own_search=%llu\\n",
          __lang_lookup_probe[0], __lang_lookup_probe[1], __lang_lookup_probe[2], __lang_lookup_probe[3],
          __lang_lookup_probe[4], __lang_lookup_probe[5], __lang_lookup_probe[6]);
}
''' + marker)
replace('    uintptr_t w = *p;', '    __lang_lookup_probe[0]++;\n    uintptr_t w = *p;')
if b'static inline size_t __lang_scan_span(' in source:
    replace('  size_t lo = st->last;', '  __lang_lookup_probe[1]++;\n  size_t lo = st->last;')
    replace('    size_t l2 = 0, h2 = st->nsp;', '    __lang_lookup_probe[2]++;\n    size_t l2 = 0, h2 = st->nsp;')
    replace('    if (l2 >= st->nsp || a < st->sp[l2].lo) {',
            '    if (l2 >= st->nsp || a < st->sp[l2].lo) { __lang_lookup_probe[3]++;')
    replace('  if (a >= hint->lo && a < hint->hi) {',
            '  if (a >= hint->lo && a < hint->hi) { __lang_lookup_probe[4]++;')
    replace('    if (!hint->span) return SIZE_MAX;',
            '    if (!hint->span) { __lang_lookup_probe[5]++; return SIZE_MAX; }')
else:
    replace('    size_t lo = st->last;', '    __lang_lookup_probe[1]++;\n    size_t lo = st->last;')
    replace('      size_t l2 = 0, h2 = st->nsp;', '      __lang_lookup_probe[2]++;\n      size_t l2 = 0, h2 = st->nsp;')
    replace('      if (l2 >= st->nsp || a < st->sp[l2].lo) continue;',
            '      if (l2 >= st->nsp || a < st->sp[l2].lo) { __lang_lookup_probe[3]++; continue; }')
if b'static int __lang_scan_own(' in source:
    replace('  size_t a0 = 0, z0 = st->nown;', '  __lang_lookup_probe[6]++;\n  size_t a0 = 0, z0 = st->nown;')
else:
    replace('    size_t a0 = 0, z0 = st->nown;', '    __lang_lookup_probe[6]++;\n    size_t a0 = 0, z0 = st->nown;')
Path(sys.argv[2]).write_bytes(source)

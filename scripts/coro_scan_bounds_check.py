#!/usr/bin/env python3
"""Check that a conservative scan reads no further than the allocation a pointer is in.

test/coro/scan_bounds_contract.c runs the runtime's own scan over words it
chooses: a held node's dead neighbour is not reported, a held neighbour is, an
interior pointer reads the rest of its allocation and not the next, the last
allocation in a block is read up to the bump pointer, a block of its own is
read 16 words, and a region's bytes handed out again keep no start of their
earlier use. Healthy, at -O2 and under ASan/UBSan, as an executable and as a
library instance; and each mutation below must be caught by the assertion
named for it.
"""
import os
from pathlib import Path
import resource
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MERE = os.environ.get('MERE', str(ROOT / '_build/default/bin/mere.exe'))
CC = os.environ.get('CC', 'clang')

MUTATIONS = {
    'healthy': None,
    # the scan reads 16 words whatever the map says
    'unbounded': ('    if (blk->starts) {\n      uintptr_t base = (uintptr_t)(blk + 1);',
                  '    if (0) {\n      uintptr_t base = (uintptr_t)(blk + 1);',
                  'read past the allocation into a dead neighbour'),
    # the allocator marks no starts
    'unmarked': ('if (__s) { size_t __i = (size_t)((char*)p - r->base) >> 3;', 'if (0) { size_t __i = (size_t)((char*)p - r->base) >> 3;',
                 'read past the allocation into a dead neighbour'),
    # a released region keeps its starts for the next use
    'stale-after-release': ('    if (zlen) __lang_starts_clear(r->blocks,', '    if (0) __lang_starts_clear(r->blocks,',
                            'start at or above the bump pointer'),
    # the scan stops at the allocation's own start (off by one)
    'stops-at-own-start': ('      size_t j = ((a - base) >> 3) + 1,', '      size_t j = ((a - base) >> 3),',
                           'held node'),
}


def main():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    with tempfile.TemporaryDirectory(prefix='mere-scan-bounds-') as directory:
        temp = Path(directory)
        source = temp / 'probe.mere'
        source.write_text('let root = coro_root ();\n'
                          'let c = coro_new (fn _me -> fn (_u: unit) -> coro_exit root ());\n'
                          'let _ = coro_scan_ints c 0 1 (fn (n: int) -> ());\n'
                          'let _ = coro_switch c; ()\n')
        fixture = ROOT / 'test/coro/scan_bounds_contract.c'
        for library in (False, True):
            command = [MERE] + (['--lib-instance'] if library else []) + ['-c', str(source)]
            runtime = subprocess.check_output(command, text=True, timeout=60)
            for label, mutation in MUTATIONS.items():
                text = runtime
                if mutation:
                    old, new, _ = mutation
                    if text.count(old) != 1:
                        raise AssertionError(('mutation must match once', label, text.count(old)))
                    text = text.replace(old, new)
                (temp / 'runtime.c').write_text(text)
                modes = ('O2', 'sanitized') if label == 'healthy' else ('O2',)
                for mode in modes:
                    binary = temp / 'probe'
                    flags = ['-O2'] if mode == 'O2' else ['-O1', '-g', '-fsanitize=address,undefined',
                                                        '-fno-sanitize-recover=all']
                    subprocess.run([CC, *flags, '-w', '-pthread', '-I', str(temp), str(fixture),
                                    '-lm', '-o', str(binary)], check=True, timeout=90)
                    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30,
                                            env=dict(os.environ, ASAN_OPTIONS='detect_leaks=0',
                                                     UBSAN_OPTIONS='halt_on_error=1'))
                    if label == 'healthy':
                        if result.returncode or result.stdout != 'coroutine scan bounds contracts passed\n':
                            raise AssertionError((library, mode, result.returncode, result.stdout, result.stderr))
                    elif result.returncode == 0 or mutation[2] not in result.stderr:
                        raise AssertionError(('missing oracle witness', library, label,
                                              result.returncode, result.stdout, result.stderr))
            # a program that never asks what a stack reaches pays nothing: no
            # map is made and no allocation marks one
            plain = temp / 'plain.mere'
            plain.write_text('let root = coro_root ();\n'
                             'let c = coro_new (fn _me -> fn (_u: unit) -> coro_exit root ());\n'
                             'let _ = coro_switch c; ()\n')
            text = subprocess.check_output([MERE] + (['--lib-instance'] if library else []) + ['-c', str(plain)],
                                           text=True, timeout=60)
            if 'calloc((cap + 63) / 64, 1)' in text or 'unsigned char* __s = r->blocks->starts' in text:
                raise AssertionError(('a program that does not scan builds the start map', library))
            if 'calloc((cap + 63) / 64, 1)' not in runtime or 'unsigned char* __s = r->blocks->starts' not in runtime:
                raise AssertionError(('a program that scans builds no start map', library))
            print(('library' if library else 'executable') +
                  f': O2 and ASan/UBSan scan bounds contracts passed; {len(MUTATIONS) - 1} mutations caught',
                  flush=True)


if __name__ == '__main__':
    main()

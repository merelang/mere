#!/usr/bin/env python3
"""Check cached span lookup against linear membership and failure witnesses."""
import os
from pathlib import Path
import resource
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MERE = os.environ.get('MERE', str(ROOT / '_build/default/bin/mere.exe'))
CC = os.environ.get('CC', 'clang')


def main():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    with tempfile.TemporaryDirectory(prefix='mere-span-cache-') as directory:
        temp = Path(directory)
        source = temp / 'probe.mere'
        source.write_text('let root = coro_root ();\n'
                          'let c = coro_new (fn _me -> fn (_u: unit) -> coro_exit root ());\n'
                          'let _ = coro_switch c; ()\n')
        for library in (False, True):
            command = [MERE] + (['--lib-instance'] if library else []) + ['-c', str(source)]
            runtime = subprocess.check_output(command, text=True, timeout=60)
            marker = '    size_t l2 = 0, h2 = st->nsp;'
            assert runtime.count(marker) == 1
            runtime = runtime.replace(marker, '    lookup_searches++;\n' + marker)
            mutations = {
                'healthy': None,
                'range-check': ('if (a >= hint->lo && a < hint->hi)', 'if (hint->hi)',
                                'span cache differs from linear reference'),
                'exclusive-end': ('a < hint->hi', 'a <= hint->hi',
                                  'span cache differs from linear reference'),
                'gap-hit': ('if (!hint->span) return SIZE_MAX;', 'if (!hint->span) return st->last;',
                            'span cache differs from linear reference'),
                'span-index': ('lo = hint->span - 1;', 'lo = hint->span;',
                               'span cache differs from linear reference'),
                'cached-ownership': ('st->last_own = hint->own;', 'st->last_own = !hint->own;',
                                     'cached ownership differs from linear reference'),
                'initial-ownership': ('if (!st->last_own_valid)', 'if (0)',
                                      'cached ownership differs from linear reference'),
                'used-limit': ('if (a >= used) continue;', 'if (0) continue;',
                               'scanner followed unused capacity'),
                'cache-disabled': ('if (a >= hint->lo && a < hint->hi)', 'if (0)',
                                   'span cache repeated binary search'),
                'gap-cache-disabled': ('hint->hi = l2 < st->nsp ? st->sp[l2].lo : UINTPTR_MAX;',
                                       'hint->hi = hint->lo;', 'gap cache repeated binary search'),
            }
            for label, mutation in mutations.items():
                text = runtime
                if mutation:
                    old, new, witness = mutation
                    assert text.count(old) == 1, ('mutation must match once', library, label)
                    text = text.replace(old, new)
                (temp / 'runtime.c').write_text(text)
                modes = ('O2', 'sanitized') if label == 'healthy' else ('O2',)
                for mode in modes:
                    binary = temp / 'probe'
                    flags = ['-O2'] if mode == 'O2' else ['-O1', '-g', '-fsanitize=address,undefined',
                                                        '-fno-sanitize-recover=all']
                    subprocess.run([CC, *flags, '-w', '-pthread', '-I', str(temp),
                                    str(ROOT / 'test/coro/span_cache_contract.c'), '-lm', '-o', str(binary)],
                                   check=True, timeout=90)
                    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=60,
                                            env=dict(os.environ, ASAN_OPTIONS='detect_leaks=0',
                                                     UBSAN_OPTIONS='halt_on_error=1'))
                    if label == 'healthy':
                        if result.returncode or result.stdout != 'coroutine span cache contracts passed\n':
                            raise AssertionError((library, mode, result.returncode, result.stdout, result.stderr))
                    elif result.returncode == 0 or witness not in result.stderr:
                        raise AssertionError(('missing oracle witness', library, label,
                                              result.returncode, result.stdout, result.stderr))
            print(('library' if library else 'executable') +
                  ': O2 and ASan/UBSan span cache contracts passed; nine mutations caught', flush=True)


if __name__ == '__main__':
    main()

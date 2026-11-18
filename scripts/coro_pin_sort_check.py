#!/usr/bin/env python3
"""Compare native pin sorting against qsort, including failure controls."""
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
    with tempfile.TemporaryDirectory(prefix='mere-pin-sort-') as directory:
        temp = Path(directory)
        source = temp / 'probe.mere'
        source.write_text('let root = coro_root ();\n'
                          'let c = coro_new (fn _me -> fn (_u: unit) -> coro_exit root ());\n'
                          'let _ = coro_switch c; ()\n')
        for library in (False, True):
            command = [MERE] + (['--lib-instance'] if library else []) + ['-c', str(source)]
            runtime = subprocess.check_output(command, text=True, timeout=60)
            assert runtime.count('__lang_pin_sort(x->pw, x->pn);') == 1
            assert runtime.count('__lang_pin_sort(c->x->pw, c->x->pn);') == 1
            mutations = {
                'healthy': None,
                'highest-byte': ('byte < sizeof(uintptr_t)', 'byte + 1 < sizeof(uintptr_t)',
                                 'pin sort differs from reference'),
                'unstable-pass': ('for (size_t i = 0; i < n; i++) { uintptr_t word = from[i];',
                                  'for (size_t i = n; i-- > 0;) { uintptr_t word = from[i];',
                                  'pin sort differs from reference'),
                'copy-back': ('if (from != words) memcpy(words, from, n * sizeof(uintptr_t));', '',
                              'pin sort differs from reference'),
                'allocation-fallback': ('if (!scratch) { qsort(words, n, sizeof(uintptr_t), __lang_uptr_cmp); return; }',
                                         'if (!scratch) return;', 'pin sort fallback missing'),
                'scratch-release': ('free(scratch);', '', 'pin sort scratch retained'),
                'comparison-sort': ('if (n < 256)', 'if (n < SIZE_MAX)', 'large pin sort used qsort'),
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
                                    str(ROOT / 'test/coro/pin_sort_contract.c'), '-lm', '-o', str(binary)],
                                   check=True, timeout=90)
                    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=60,
                                            env=dict(os.environ, ASAN_OPTIONS='detect_leaks=0',
                                                     UBSAN_OPTIONS='halt_on_error=1'))
                    if label == 'healthy':
                        if result.returncode or result.stdout != 'coroutine pin sort contracts passed\n':
                            raise AssertionError((library, mode, result.returncode, result.stdout, result.stderr))
                    elif result.returncode == 0 or witness not in result.stderr:
                        raise AssertionError(('missing oracle witness', library, label,
                                              result.returncode, result.stdout, result.stderr))
            print(('library' if library else 'executable') +
                  ': O2 and ASan/UBSan pin sort contracts passed; six mutations caught', flush=True)


if __name__ == '__main__':
    main()

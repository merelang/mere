#!/usr/bin/env python3
"""Check incremental scan snapshots, fallback paths and failure witnesses."""
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
    with tempfile.TemporaryDirectory(prefix='mere-scan-index-') as directory:
        temp = Path(directory)
        source = temp / 'probe.mere'
        source.write_text('let root = coro_root ();\n'
                          'let c = coro_new (fn _me -> fn (_u: unit) -> coro_exit root ());\n'
                          'let _ = coro_switch c; ()\n')
        fixture = ROOT / 'test/coro/scan_index_contract.c'
        for library in (False, True):
            command = [MERE] + (['--lib-instance'] if library else []) + ['-c', str(source)]
            runtime = subprocess.check_output(command, text=True, timeout=60)
            mutations = {
                'healthy': None,
                'missing-add': ('if (__lang_scan_note_block) __lang_scan_note_block(b, 1);', ''),
                'missing-remove': ('if (__lang_scan_note_block) __lang_scan_note_block(b, 0);', ''),
                'stale-shared': ('if (__lang_scan_sp && __lang_scan_dlgen == __lang_blk_dl_gen)',
                                 'if (__lang_scan_sp)'),
                'truncated-log': ('if (!__lang_scan_overflow && __lang_scan_tlgen + __lang_scan_nchanges == __lang_blk_tl_gen)',
                                  'if (1)'),
                'unpublished-capacity': ('  nb->pad = new_al;\n  __lang_blk_link(r, nb);',
                                         '  __lang_blk_link(r, nb);\n  nb->pad = new_al;'),
            }
            for label, mutation in mutations.items():
                text = runtime
                if mutation:
                    old, new = mutation
                    if text.count(old) != 1:
                        raise AssertionError(('mutation must match once', label))
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
                        if result.returncode or result.stdout != 'coroutine scan index contracts passed\n':
                            raise AssertionError((library, mode, result.returncode, result.stdout, result.stderr))
                    else:
                        witness = ('full_sorts == sorts' if label.startswith('missing-') else
                                   'expected[i].hi == __lang_scan_sp[i].hi' if label == 'unpublished-capacity' else
                                   'n == __lang_scan_nsp')
                        if result.returncode == 0 or witness not in result.stderr:
                            raise AssertionError(('missing oracle witness', library, label,
                                                  result.returncode, result.stdout, result.stderr))
            print(('library' if library else 'executable') +
                  ': O2 and ASan/UBSan index contracts passed; five mutations caught', flush=True)


if __name__ == '__main__':
    main()

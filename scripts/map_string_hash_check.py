#!/usr/bin/env python3
"""Check indexed string keys and bounded hash reads at every word/tail length."""
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MERE = os.environ.get("MERE", str(ROOT / "_build/default/bin/mere.exe"))
SOURCE = ROOT / "test/parity/map_string_key_lengths.mere"
EXPECTED = b"true\n" * 6
GUARDS = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
static size_t key_length;
static size_t __lang_str_size(const char *text) { (void)text; return key_length; }
HASH_HELPERS
int main(void) {
  size_t page = (size_t)sysconf(_SC_PAGESIZE);
  unsigned char *area = mmap(NULL, page * 3, PROT_NONE,
                            MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  assert(area != MAP_FAILED);
  unsigned char *live = area + page;
  assert(mprotect(live, page, PROT_READ | PROT_WRITE) == 0);
  unsigned char *copy = malloc(page + 8);
  assert(copy != NULL);
  unsigned checks = 0;
  for (size_t length = 0; length <= page; length++) {
    key_length = length;
    for (unsigned edge = 0; edge < 2; edge++) {
      unsigned char *key = edge ? live + page - length : live;
      for (size_t i = 0; i < length; i++) key[i] = (unsigned char)(i * 131 + length);
      unsigned long long wanted = __lang_hash_str((const char *)key);
      for (unsigned alignment = 0; alignment < 8; alignment++) {
        memcpy(copy + alignment, key, length);
        assert(__lang_hash_str((const char *)copy + alignment) == wanted);
        checks++;
      }
    }
  }
  free(copy);
  assert(munmap(area, page * 3) == 0);
  printf("Map string hash: %u aligned/unaligned guard-page comparisons\n", checks);
  return 0;
}
'''


def main():
    emitted = subprocess.run([MERE, "-c", str(SOURCE)], capture_output=True,
                             check=True, timeout=120).stdout.decode()
    # Extract the actual emitted helpers. The size stub isolates the hash's
    # bounded reader; the language fixture above tests real string metadata.
    helpers = re.search(r"static unsigned long long __lang_hash_u64\(.*?"
                        r"(?=typedef struct mere_map_)", emitted, re.S)
    assert helpers, "generated map hash helpers were not found"
    with tempfile.TemporaryDirectory(prefix="mere-map-string-") as directory:
        temp = Path(directory)
        program = temp / "map.c"
        program.write_text(emitted)
        bounds = temp / "bounds.c"
        bounds.write_text(GUARDS.replace("HASH_HELPERS", helpers.group()))
        for mode, flags in [("O2", ["-O2"]),
                            ("sanitizers", ["-O1", "-fsanitize=address,undefined",
                                            "-fno-sanitize-recover=all",
                                            "-fno-omit-frame-pointer"])]:
            for name, source in [("map", program), ("bounds", bounds)]:
                binary = temp / (name + "-" + mode)
                subprocess.run([os.environ.get("CC", "clang"), *flags, "-w",
                                "-fbracket-depth=1024", str(source), "-lm",
                                "-o", str(binary)], check=True, timeout=120)
                result = subprocess.run([str(binary)], capture_output=True, check=True,
                                        timeout=60,
                                        env=dict(os.environ, ASAN_OPTIONS="detect_leaks=0"))
                if name == "map":
                    assert result.stdout == EXPECTED, (mode, result.stdout, result.stderr)
                else:
                    print(mode, result.stdout.decode().strip(), flush=True)
    print("String-key lookup, binary lengths, compound keys, order, deletion, "
          "reinsertion, compact and recycle passed (O2/ASan/UBSan)", flush=True)


if __name__ == "__main__":
    main()

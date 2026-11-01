#!/bin/sh
# Compile and run generated C with the selected compiler, including its default
# language mode. --emit makes a portable bundle for compiler-only containers;
# --check needs only a C compiler and Perl, not OCaml or Mere.
set -eu

MODE=${1:-}
[ "$#" -eq 2 ] || { echo "usage: $0 --emit|--check <directory>" >&2; exit 2; }
mkdir -p "$2"
CASES=$(cd "$2" && pwd)

case "$MODE" in
  --emit)
    ROOT=$(cd "$(dirname "$0")/.." && pwd)
    MERE=${MERE:-$ROOT/_build/default/bin/mere.exe}
    cp "$ROOT/scripts/c_compiler_check.sh" "$CASES/check.sh"
    cp "$ROOT/scripts/bounded.sh" "$CASES/bounded.sh"
    cd "$ROOT"
    for fixture in test/parity/try_or_unwind.mere test/threadfail/join_caught.mere test/coro/nested.mere; do
      name=$(basename "$fixture" .mere)
      "$MERE" -c "$fixture" > "$CASES/$name.c"
    done
    printf '7\n42\n99\n11\n600\n2001000\n5\n2001000\n2\n22\n20000\n33\n1\n' > "$CASES/try_or_unwind.out"
    printf '7\n' > "$CASES/join_caught.out"
    printf 'main caught: -1\nB caught: 5\nmain: done\n' > "$CASES/nested.out"
    for name in try_or_unwind nested library; do : > "$CASES/$name.err"; done
    printf 'mere: thread 1 failed: fail: boom\n' > "$CASES/join_caught.err"
    cat > "$CASES/library.mere" <<'MERE'
let boom = fn (n: int) -> if n == 0 then fail "library boom" else n + 1;
()
MERE
    # The basename determines the exported C symbol prefix.
    "$MERE" --header "$CASES/library.mere" > "$CASES/library.h"
    "$MERE" -c --lib "$CASES/library.mere" > "$CASES/library.c"
    cat > "$CASES/host.c" <<'C'
#include <stdio.h>
#include "library.h"
int main(void) {
  long long value;
  mere_buf err;
  if (mere_library_boom(0, &value, &err) != MERE_FAIL) return 1;
  printf("%.*s\n", (int)err.len, err.ptr);
  mere_lib_free((void*)err.ptr);
  if (mere_library_boom(6, &value, &err) != MERE_OK) return 1;
  printf("after=%lld\n", value);
  mere_lib_shutdown();
  return 0;
}
C
    printf 'fail: library boom\nafter=7\n' > "$CASES/library.out"
    echo "Generated C compiler fixtures"
    ;;
  --check)
    CC=${CC:-cc}
    command -v "$CC" >/dev/null
    command -v perl >/dev/null
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    "$CC" --version | head -1
    for standard in default gnu11 gnu17 gnu2x; do
      for optimization in 0 2; do
        set -- "-O$optimization"
        [ "$standard" = default ] || set -- "$@" "-std=$standard"
        for name in try_or_unwind join_caught nested library; do
          if [ "$name" = library ]; then
            "$CC" "$@" -fPIC -shared "$CASES/library.c" -pthread -lm -o "$TMP/library.so"
            "$CC" "$@" "$CASES/host.c" "$TMP/library.so" -pthread -lm -o "$TMP/program"
          else
            "$CC" "$@" "$CASES/$name.c" -pthread -lm -o "$TMP/program"
          fi
          if sh "$CASES/bounded.sh" 30 "$TMP/program" > "$TMP/out" 2> "$TMP/err"; then
            :
          else
            status=$?
            echo "FAIL $standard -O$optimization $name: exit $status" >&2
            cat "$TMP/out" "$TMP/err" >&2
            exit 1
          fi
          diff -u "$CASES/$name.out" "$TMP/out" || { echo "FAIL $standard -O$optimization $name stdout" >&2; exit 1; }
          diff -u "$CASES/$name.err" "$TMP/err" || { echo "FAIL $standard -O$optimization $name stderr" >&2; exit 1; }
          echo "PASS $standard -O$optimization $name"
        done
      done
    done
    ;;
  *) echo "unknown mode: $MODE" >&2; exit 2 ;;
esac

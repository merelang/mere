#!/bin/sh
# Exercise the distribution binary, without an OCaml installation. Linux mode
# runs the same bytes in stock Ubuntu images, with no packages installed.
set -eu

[ "$#" -eq 3 ] || { echo "usage: $0 --native|--linux <binary> <version>" >&2; exit 2; }
MODE=$1
ASSET=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
VERSION=$3
SCRIPTS=$(cd "$(dirname "$0")" && pwd)
[ -x "$ASSET" ] || { echo "release runtime: binary is not executable" >&2; exit 1; }

case "$MODE" in
  --linux)
    command -v docker >/dev/null
    for image in ubuntu:24.04 ubuntu:26.04; do
      # Fail before execution if the image cannot be obtained. A skipped runtime
      # is not evidence that a distribution binary works there.
      docker pull --platform linux/amd64 "$image"
      echo "Checking distribution binary on $image"
      sh "$SCRIPTS/bounded.sh" 180 docker run --rm --platform linux/amd64 \
        --network none \
        -v "$ASSET:/asset/mere:ro" -v "$SCRIPTS:/checks:ro" \
        "$image" sh /checks/release_runtime_check.sh --native /asset/mere "$VERSION"
    done
    ;;
  --native)
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    run() {
      if command -v timeout >/dev/null 2>&1; then timeout 30 "$@"
      else sh "$SCRIPTS/bounded.sh" 30 "$@"; fi
    }
    run "$ASSET" --version > "$TMP/version"
    printf 'mere v%s\n' "$VERSION" > "$TMP/want-version"
    diff -u "$TMP/want-version" "$TMP/version"
    cat > "$TMP/smoke.mere" <<'MERE'
let h = spawn (fn () -> print "thread-ok");
let _ = join h;
print (str_of_int (try_or (fn () -> fail "expected") 42))
MERE
    printf 'thread-ok\n42\n' > "$TMP/want"
    run "$ASSET" "$TMP/smoke.mere" > "$TMP/out" 2> "$TMP/err" || {
      echo "release runtime: program failed" >&2; cat "$TMP/err" >&2; exit 1;
    }
    diff -u "$TMP/want" "$TMP/out"
    [ ! -s "$TMP/err" ] || { echo "release runtime: unexpected stderr" >&2; cat "$TMP/err" >&2; exit 1; }
    for backend in c ll w; do
      run "$ASSET" "-$backend" "$TMP/smoke.mere" > "$TMP/code" 2> "$TMP/err" || {
        echo "release runtime: -$backend emission failed" >&2; cat "$TMP/err" >&2; exit 1;
      }
      [ -s "$TMP/code" ] || { echo "release runtime: -$backend emitted nothing" >&2; exit 1; }
      [ ! -s "$TMP/err" ] || { echo "release runtime: -$backend unexpected stderr" >&2; cat "$TMP/err" >&2; exit 1; }
    done
    echo "release runtime: v$VERSION passed (version, threads, caught failure, C/LLVM/Wasm emission)"
    ;;
  *) echo "release runtime: unknown mode" >&2; exit 2 ;;
esac

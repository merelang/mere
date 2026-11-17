#!/bin/sh
# scripts/downstream_cc_check.sh -- the downstreams' emitted code still COMPILES.
#
# downstream_check asks whether `mere -c` succeeds in each repository, and
# nothing asked whether a C compiler then accepts what came out. The runtime is
# text this compiler pastes into every program; a change to it reaches every
# downstream at once and is seen by none of the gates that stop at emission.
# v0.1.566-567 shipped a runtime change no gate compiled, and a build of
# mere-ruby -- the only downstream whose C carries the coroutine pool -- is what
# went looking. (That build was killed, under a load that has not been
# reproduced; see v0.1.569. This gate is for the class, not that instance.)
#
# Each row of test/downstream/CC: emit (`-c` or `-ll`) from inside the
# repository, then `$CC <its flags> -c`. Nothing is linked. A failure says which
# of three things it was, because they are three different facts:
#   compile error   the compiler refused the code (its first lines follow)
#   timeout         it outlived CC_TIMEOUT seconds (201 from bounded.sh)
#   signal N        something killed it; 9 is usually the out-of-memory killer,
#                   and two rows here peak at 6-7 GB (mere-ruby, mbrowse)
# Each row prints its seconds.
#
# REUSE. A row whose emitted code, compiler version and flags hash to a run that
# passed before is not compiled again ("reused"): mere-ruby and mbrowse are four
# minutes each here and two to three times that on CI, and most commits do not
# change what they emit. The hash is of the code itself, not of which files the
# commit touched -- the C changes with the region, mono and type passes too, and
# a path filter would be a skip that outlives its reason. The cache is
# $MERE_CC_CACHE (default ~/.cache/mere-downstream-cc); --poison never uses it.
#
# Usage: MERE_DOWNSTREAM=<dir of checkouts> sh scripts/downstream_cc_check.sh [--poison] [repo...]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
REPOS="$ROOT/test/downstream/REPOS"
TABLE="$ROOT/test/downstream/CC"
CC="${CC:-clang}"; command -v "$CC" >/dev/null 2>&1 || CC=cc
BOUND="${CC_TIMEOUT:-1200}"
CACHE="${MERE_CC_CACHE:-$HOME/.cache/mere-downstream-cc}"
DIR="${MERE_DOWNSTREAM:-}"
MODE=""; [ "${1:-}" = --poison ] && { MODE=poison; shift; }
ONLY="$*"
[ -x "$MERE" ] || { echo "downstream_cc: $MERE not found -- run 'dune build'" >&2; exit 1; }
if [ -z "$DIR" ]; then
  echo "downstream_cc: SKIP (set MERE_DOWNSTREAM=<dir of checkouts>)"
  exit 3
fi
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
rown=0

ssl_flags() {
  if command -v brew >/dev/null 2>&1 && p=$(brew --prefix openssl@3 2>/dev/null) && [ -d "$p/include" ]; then
    echo "-I$p/include"
  fi   # elsewhere the headers are in the default search path (libssl-dev)
}
sdl_flags() { command -v sdl2-config >/dev/null 2>&1 && sdl2-config --cflags; }
cc_version=$("$CC" --version 2>/dev/null | head -1)
hash_of() { { cat "$1"; echo "$cc_version"; echo "$2"; } | shasum -a 256 | cut -c1-40; }

depth_flags_valid() {
  depth_seen=0
  for depth_arg in $1; do
    case "$depth_arg" in
      -fbracket-depth*)
        [ "$depth_arg" = -fbracket-depth=256 ] || return 1
        depth_seen=$((depth_seen + 1)) ;;
    esac
  done
  [ "$depth_seen" -eq 1 ]
}
target_flags() {
  awk '$1 == "mere-ruby" && $2 == "c" {
    n++; for (i=3; i<=NF; i++) printf "%s%s", (i>3 ? " " : ""), $i
  } END { if (n != 1) exit 1; print "" }' "$1"
}
if ! mr_flags=$(target_flags "$TABLE"); then
  echo "FAIL downstream_cc: exactly one required mere-ruby C row must be declared"; exit 1
fi
if ! depth_flags_valid "$mr_flags"; then
  echo "FAIL downstream_cc: mere-ruby requires exactly one -fbracket-depth=256"; exit 1
fi

# one row -> prints a status line, returns 0 ok / 1 failed / 2 absent
# $1 repo $2 backend $3 flags $4 use cache (1/0) $5 sed expression or "" $6 CC override or ""
row() {
  repo=$1 be=$2 raw=$3 usecache=$4 poison=${5:-} cc=${6:-$CC}
  if [ "$repo:$be" = mere-ruby:c ] && ! depth_flags_valid "$raw"; then
    echo "FAIL downstream_cc[$repo]: requires exactly one -fbracket-depth=256"; return 1
  fi
  entry=$(awk -v r="$repo" '$1 == r { print $2; exit }' "$REPOS")
  [ -n "$entry" ] || { echo "FAIL downstream_cc[$repo]: not a row of test/downstream/REPOS"; return 1; }
  if [ ! -d "$DIR/$repo" ]; then
    if [ "$repo" = mere-ruby ]; then
      echo "FAIL downstream_cc[$repo]: required checkout missing"; return 1
    fi
    echo "  skip  $repo $be (not in \$MERE_DOWNSTREAM)"; return 2
  fi
  flags=""
  for f in $raw; do
    case "$f" in
      @ssl) flags="$flags $(ssl_flags)" ;;
      @sdl) s=$(sdl_flags) || { echo "FAIL downstream_cc[$repo]: no SDL2 headers (sdl2-config) -- install them; a skipped row is a row nobody compiles"; return 1; }
            flags="$flags $s" ;;
      *) flags="$flags $f" ;;
    esac
  done
  ext=c; lang=c; [ "$be" = ll ] && { ext=ll; lang=ir; }
  # NOT named after the repository. mere-ruby's mspec/rss_guard.sh kills -9 any
  # process over 6 GB whose command line contains "mere-ruby" -- and a clang
  # compiling ".../mere-ruby.c" peaks at 6-7 GB. It did exactly that on
  # 2026-10-02 (its log has the clang command line), while a sweep ran beside this.
  rown=$((rown + 1))
  out="$T/row$rown.$ext"
  ( cd "$DIR/$repo" && "$MERE" "-$be" "$entry" > "$out" 2>"$T/emit.err" ) \
    || { echo "FAIL downstream_cc[$repo]: $entry does not emit with -$be (downstream_check owns that question)"; sed -n '1,3p' "$T/emit.err" | sed 's/^/        /'; return 1; }
  if [ -n "$poison" ]; then sed "$poison" "$out" > "$out.p" && mv "$out.p" "$out"; fi
  key=$(hash_of "$out" "$be $flags")
  if [ "$usecache" = 1 ] && [ -f "$CACHE/$key" ]; then
    echo "  ok    $repo $be (reused: the same code passed $(cat "$CACHE/$key"))"; return 0
  fi
  t0=$(date +%s)
  # shellcheck disable=SC2086
  sh "$ROOT/scripts/bounded.sh" "$BOUND" "$cc" $flags -x "$lang" -c "$out" -o "$T/o" > "$T/cc.out" 2>&1
  rc=$?
  secs=$(( $(date +%s) - t0 ))
  if [ "$rc" = 0 ]; then
    echo "  ok    $repo $be ${secs}s"
    if [ "$usecache" = 1 ]; then mkdir -p "$CACHE" && date -u +%Y-%m-%dT%H:%MZ > "$CACHE/$key"; fi
    return 0
  elif [ "$rc" = 201 ]; then
    echo "FAIL downstream_cc[$repo]: $be timeout -- $CC outlived ${BOUND}s (CC_TIMEOUT); a cliff that slows the compiler down is a regression too"
  elif [ "$rc" -gt 128 ] || command grep -q 'Killed: [0-9]*\|failed due to signal' "$T/cc.out"; then
    # clang's DRIVER survives when its frontend is killed and exits 1 itself, so
    # the status says "error" -- its message is what says "killed"
    if [ "$rc" -gt 128 ]; then n=$((rc - 128)); else n=$(sed -n 's/.*Killed: \([0-9]*\).*/\1/p' "$T/cc.out" | head -1); [ -n "$n" ] || n=9; fi
    if [ "$n" = 9 ]; then why="usually the out-of-memory killer"; else why="not a compile error"; fi
    echo "FAIL downstream_cc[$repo]: $be killed by signal $n after ${secs}s ($why -- or a watcher that kills by name; see the comment above row())"
  else
    echo "FAIL downstream_cc[$repo]: $be compile error ($CC exited $rc)"
    command grep -m3 -E 'error' "$T/cc.out" | cut -c1-200 | sed 's/^/        /'
  fi
  return 1
}

if [ "$MODE" = poison ]; then
  # Each must go red with ITS OWN sentence, or the classification is decoration.
  pf=0
  expect() {  # $1 what, $2 the sentence that must appear, $3.. the row
    what=$1 want=$2; shift 2
    got=$(row "$@")
    case "$got" in
      *"$want"*) echo "  ok    POISON ($what): $(echo "$got" | head -1 | cut -c1-110)" ;;
      *) echo "  FAIL  POISON ($what): wanted [$want], got [$(echo "$got" | head -1)]"; pf=1 ;;
    esac
  }
  printf '#!/bin/sh\nkill -9 $$\n' > "$T/killcc"; chmod +x "$T/killcc"
  expect "the code does not compile" "c compile error" mkv c "-O2 -w" 0 '$a\
#error poisoned'
  expect "the compiler is killed" "killed by signal 9" mkv c "-O2 -w" 0 "" "$T/killcc"
  printf '#!/bin/sh\necho "clang: error: unable to execute command: Killed: 9" >&2\nexit 1\n' > "$T/drvcc"; chmod +x "$T/drvcc"
  expect "the driver reports its frontend killed" "killed by signal 9" mkv c "-O2 -w" 0 "" "$T/drvcc"
  BOUND=1 expect "the compiler is too slow" "c timeout" medit2 c "-O2 -Wno-conditional-type-mismatch" 0

  expect "missing depth flag" "requires exactly one -fbracket-depth=256" mere-ruby c "-O2 -w" 0
  expect "raised depth flag" "requires exactly one -fbracket-depth=256" mere-ruby c "-O2 -w -fbracket-depth=1024" 0
  expect "later depth override" "requires exactly one -fbracket-depth=256" mere-ruby c "$mr_flags -fbracket-depth=1024" 0
  DIR="$T/absent" expect "missing required checkout" "required checkout missing" mere-ruby c "$mr_flags" 0
  sed '/^mere-ruby[[:space:]]/d' "$TABLE" > "$T/missing-table"
  cat "$TABLE" > "$T/duplicate-table"
  printf 'mere-ruby c %s\n' "$mr_flags" >> "$T/duplicate-table"
  for table in "$T/missing-table" "$T/duplicate-table"; do
    if target_flags "$table" > /dev/null; then
      echo "  FAIL  POISON (missing or duplicated required row was accepted)"; pf=1
    else
      echo "  ok    POISON (missing or duplicated required row refused)"
    fi
  done

  # Use the actual table flags, even on Apple clang whose default is larger.
  # The same deep source must parse with 1024, so an unrelated syntax error or
  # a compiler that always fails cannot satisfy the depth refusal.
  for depth in 64 300; do
    awk -v n="$depth" 'BEGIN { printf "int depth_probe(void) { return ";
      for(i=0;i<n;i++) printf "("; printf "0";
      for(i=0;i<n;i++) printf ")"; print "; }" }' > "$T/depth-$depth.c"
  done
  wider=$(printf '%s\n' "$mr_flags" | sed 's/-fbracket-depth=256/-fbracket-depth=1024/')
  # shellcheck disable=SC2086
  if ! sh "$ROOT/scripts/bounded.sh" 10 "$CC" $mr_flags -fsyntax-only "$T/depth-64.c" > "$T/depth.out" 2>&1; then
    echo "  FAIL  POISON (valid shallow source did not compile)"; pf=1
  fi
  # shellcheck disable=SC2086
  if sh "$ROOT/scripts/bounded.sh" 10 "$CC" $mr_flags -fsyntax-only "$T/depth-300.c" > "$T/depth.out" 2>&1; then
    echo "  FAIL  POISON (table flags accepted 300 nested parentheses)"; pf=1
  elif ! command grep -q 'bracket nesting level exceeded' "$T/depth.out"; then
    echo "  FAIL  POISON (deep source failed for an unrelated reason)"; pf=1
  else
    echo "  ok    POISON (actual table flags refuse excessive nesting)"
  fi
  # shellcheck disable=SC2086
  if ! sh "$ROOT/scripts/bounded.sh" 10 "$CC" $wider -fsyntax-only "$T/depth-300.c" > "$T/depth.out" 2>&1; then
    echo "  FAIL  POISON (the same deep source did not compile at 1024)"; pf=1
  fi
  if [ "$(hash_of "$T/depth-64.c" "c $mr_flags")" = "$(hash_of "$T/depth-64.c" "c $wider")" ]; then
    echo "  FAIL  POISON (a depth-1024 cache entry could satisfy depth 256)"; pf=1
  else
    echo "  ok    POISON (depth flags distinguish compile cache entries)"
  fi
  [ "$pf" = 0 ] || { echo "downstream_cc --poison: FAILED"; exit 1; }
  echo "downstream_cc --poison: ok (failure classes, strict depth 256 and cache identity)"
  exit 0
fi

fails=0 ran=0 absent=0
while read -r repo be flags; do
  case "$repo" in ''|\#*) continue ;; esac
  if [ -n "$ONLY" ]; then case " $ONLY " in *" $repo "*) ;; *) continue ;; esac; fi
  row "$repo" "$be" "$flags" 1; st=$?
  case "$st" in 0) ran=$((ran + 1)) ;; 1) ran=$((ran + 1)); fails=$((fails + 1)) ;; 2) absent=$((absent + 1)) ;; esac
done < "$TABLE"
if [ "$fails" -gt 0 ]; then echo "downstream_cc: $fails failed, $ran compiled, $absent absent"; exit 1; fi
if [ "$ran" -eq 0 ]; then echo "downstream_cc: FAIL -- MERE_DOWNSTREAM is set but nothing was there to compile ($absent absent)"; exit 1; fi
echo "downstream_cc: $ran compiled, $absent absent"

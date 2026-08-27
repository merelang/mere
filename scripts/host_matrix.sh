#!/bin/sh
# scripts/host_matrix.sh — ask the compiler which backends really have which host
# builtins, and fail if the answer has changed.
#
# There have been three hand-written versions of this matrix: a table in the design
# notes, and one list per backend in `codegen_llvm.ml` / `codegen_wasm.ml` naming the
# builtins with no lowering. All three go stale silently — `print_int` gained real
# lowerings in v0.1.190 and `file_pwrite_bytes` in v0.1.222, and both are still listed
# as missing in code that is merely inert rather than wrong. A table nobody can trust
# is worse than no table.
#
# So this one is produced by asking. For each builtin, a one-line program that uses it
# is emitted for each backend and the outcome recorded:
#
#   yes       the backend emitted code, and for C the emitted C also compiles
#   nocompile the backend emitted code and a C compiler then rejected it
#   refused   the backend said it has no lowering — loud, and fine
#   MISSING   "unbound variable" — the compiler blamed the user for a backend hole
#   error     anything else (shown, so it can be looked at)
#
# `nocompile` exists because `floor`, `ceil` and `round` sat in this table's blind
# spot for as long as they had been in the environment: emission SUCCEEDED and the
# C compiler then failed on an undeclared identifier. A matrix that only asks "did
# it emit" calls that `yes`.
#
# `MISSING` is the one that matters: it is the failure mode Mere's loud-failure rule
# exists to prevent, and it is invisible until somebody writes that program.
#
# The result is written to docs/host-matrix.md and compared against what is checked
# in. Run with `--update` to accept a change.
#
# What this cannot see: a builtin that compiles and then does nothing. `tcp_set_timeout`
# on Wasm returned the same 0 its C twin returns on success and left the next read
# blocking forever (v0.1.227). Only running a program catches that — see
# scripts/socket_parity.sh and scripts/parity.sh.
#
# Usage:
#   sh scripts/host_matrix.sh [--update]

set -e

MERE=${MERE:-./_build/default/bin/mere.exe}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/docs/host-matrix.md"
UPDATE=0
[ "$1" = "--update" ] && UPDATE=1

if [ ! -x "$MERE" ]; then
  echo "host_matrix: $MERE not found — run dune build first" >&2
  exit 1
fi

CC="${CC:-clang}"; command -v "$CC" >/dev/null 2>&1 || CC=cc
have_cc=0; command -v "$CC" >/dev/null 2>&1 && have_cc=1

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The set of builtins to probe used to be a hand-written list, which is how fifteen
# names that no compiled backend implements went unnoticed: the harness whose job is
# to ask which backend has which builtin was asking about a set somebody remembered.
#
# Now the set comes from the compiler too. `mere --dump-builtins` prints every name in
# the typer's initial environment with its type, and a probe program is synthesized
# from the type — one literal per argument. What cannot be synthesized falls back to
# the hand-written overrides below, and what is neither is COUNTED and named, so the
# part of the environment this harness cannot see is a number rather than a silence.

cat > "$TMP/overrides" <<'CASES'
print_bytes|let _ = print_bytes (bytes_of_str "x"); 0
read_file|let s = read_file "/dev/null"; str_len s
write_file|let _ = write_file "/dev/null" "x"; 0
read_file_bytes|let v = read_file_bytes "/dev/null"; vec_len v
write_file_bytes|let _ = write_file_bytes "/dev/null" (vec_new ()); 0
read_bytes|let b = read_bytes "/dev/null"; bytes_len b
write_bytes|let _ = write_bytes "/dev/null" (bytes_of_str "x"); 0
read_lines|let xs = read_lines "/dev/null"; 0
file_size|let n = file_size "/dev/null"; n
list_dir|let xs = list_dir "/tmp"; 0
mkdir_p|let _ = mkdir_p "/tmp/mere_probe"; 0
spawn|let _ = spawn (fn () -> ()); 0
join|let h = spawn (fn () -> ()); let _ = join h; 0
detach|let h = spawn (fn () -> ()); let _ = detach h; 0
channel_new|let c = channel_new (); let _ = channel_send c 1; 0
channel_send|let c = channel_new (); let _ = channel_send c 1; 0
channel_recv|let c = channel_new (); let _ = channel_send c 1; let v = channel_recv c; v
channel_close|let c = channel_new (); let _ = channel_send c 1; let _ = channel_close c; 0
channel_recv_opt|let c = channel_new (); let _ = channel_send c 1; let _ = channel_recv_opt c; 0
channel_recv_timeout|let c = channel_new (); let _ = channel_send c 1; let _ = channel_recv_timeout c 10; 0
file_open|let f = file_open "/dev/null"; let _ = file_close f; 0
file_read_line|let f = file_open "/dev/null"; let s = file_read_line f; 0
file_openrw|let f = file_openrw "/tmp/mere_probe.bin"; let _ = file_close f; 0
file_pread|let f = file_open "/dev/null"; let v = file_pread f 0 4; vec_len v
file_pwrite|let f = file_openrw "/tmp/mere_probe.bin"; let n = file_pwrite f 0 (vec_new ()); n
file_pwrite_bytes|let f = file_openrw "/tmp/mere_probe.bin"; let n = file_pwrite_bytes f 0 (bytes_of_str "x"); n
map_new|let m = map_new (); let _ = map_set m "k" 1; 0
owned_vec_new|let v = owned_vec_new (); let _ = owned_vec_push v 1; 0
CASES

"$MERE" --dump-builtins > "$TMP/builtins.tsv"

OVERRIDES="$TMP/overrides" BUILTINS="$TMP/builtins.tsv" CASES_OUT="$TMP/cases" \
python3 - <<'PYGEN' 2> "$TMP/gen.log"
import os, sys

# pp_ty prints fully parenthesised, so splitting at the first top-level `->` peels
# one argument at a time.
def split_arrow(t):
    t = t.strip()
    while t.startswith("(") and t.endswith(")"):
        depth = 0
        for i, ch in enumerate(t):
            if ch == "(": depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0 and i != len(t) - 1: return None if False else _split_top(t)
        t = t[1:-1].strip()
    return _split_top(t)

def _split_top(t):
    depth = 0
    i = 0
    while i < len(t):
        c = t[i]
        if c == "(": depth += 1
        elif c == ")": depth -= 1
        elif depth == 0 and t.startswith("->", i):
            return (t[:i].strip(), t[i+2:].strip())
        i += 1
    return None

LITERAL = {"int": "1", "float": "1.0", "str": '"x"', "bool": "true", "unit": "()"}

def synth(name, ty):
    args, cur = [], ty
    while True:
        cur_s = cur.strip()
        while cur_s.startswith("(") and cur_s.endswith(")") and _split_top(cur_s[1:-1]) is not None:
            cur_s = cur_s[1:-1].strip()
        parts = _split_top(cur_s)
        if parts is None: break
        a, rest = parts
        a = a.strip()
        while a.startswith("(") and a.endswith(")"): a = a[1:-1].strip()
        if a not in LITERAL: return None, "argument of type " + a
        args.append(LITERAL[a])
        cur = rest
    if not args: return "let _ = " + name + "; 0", None
    return "let _ = " + name + " " + " ".join(args) + "; 0", None

overrides = {}
with open(os.environ["OVERRIDES"]) as f:
    for line in f:
        if "|" in line: overrides[line.split("|", 1)[0]] = line.rstrip("\n").split("|", 1)[1]

rows, skipped = [], []
with open(os.environ["BUILTINS"]) as f:
    for line in f:
        if "\t" not in line: continue
        name, ty = line.rstrip("\n").split("\t", 1)
        if name in overrides:
            rows.append((name, overrides[name])); continue
        prog, why = synth(name, ty)
        if prog is None: skipped.append((name, why))
        else: rows.append((name, prog))

rows.sort()
with open(os.environ["CASES_OUT"], "w") as out:
    for name, prog in rows: out.write(name + "|" + prog + "\n")

sys.stderr.write("%d in the environment, %d probed (%d by override), %d not synthesizable\n"
                 % (len(rows) + len(skipped), len(rows), len(overrides), len(skipped)))
for name, why in sorted(skipped):
    sys.stderr.write("    %-22s %s\n" % (name, why))
PYGEN
gen_summary=$(head -1 "$TMP/gen.log")

# A synthesized program still has to type-check — the point is to reach codegen, and
# anything the typer rejects would measure nothing. Dropped ones are counted, not
# hidden.
: > "$TMP/cases_ok"
dropped=0
while IFS='|' read -r name prog; do
  [ -z "$name" ] && continue
  printf '%s\n' "$prog" > "$TMP/tc.mere"
  if "$MERE" -t "$TMP/tc.mere" >/dev/null 2>&1; then
    printf '%s|%s\n' "$name" "$prog" >> "$TMP/cases_ok"
  else
    dropped=$((dropped + 1))
    printf '%s\n' "$name" >> "$TMP/dropped"
  fi
done < "$TMP/cases"
mv "$TMP/cases_ok" "$TMP/cases"

classify() {  # classify <flag> <file>
  if "$MERE" "$1" "$2" > "$TMP/emitted" 2>"$TMP/err"; then
    # Emitting is not the same as working. For C the emitted source is handed to a
    # compiler, which is where an undeclared identifier for a builtin nobody lowered
    # actually shows up.
    if [ "$1" = "-c" ] && [ "$have_cc" = 1 ] \
       && ! "$CC" -fsyntax-only -w -x c "$TMP/emitted" 2>/dev/null; then
      echo nocompile
    else
      echo yes
    fi
  elif grep -q 'unbound variable' "$TMP/err"; then
    echo MISSING
  elif grep -q 'bare-metal target' "$TMP/err"; then
    # Neither `yes` nor `refused`: RV32I HAS these, on `--bare` only, where the
    # program is handed the machine instead of a host. Calling that refused
    # would be the matrix lying in the flattering direction about a backend,
    # and calling it yes would be lying in the other one.
    echo bare
  elif grep -qE 'no (LLVM|Wasm|RV32I) lowering|unsupported' "$TMP/err"; then
    echo refused
  else
    echo error
  fi
}

{
  echo "# Host builtin support, by backend"
  echo
  echo "**Generated by \`scripts/host_matrix.sh\`. Do not edit.**"
  echo
  echo "Which backends have a lowering for each host / IO builtin, asked of the"
  echo "compiler rather than remembered. \`refused\` means the backend says so itself,"
  echo "which is the correct way to lack something; \`MISSING\` means a program using it"
  echo "fails with \`unbound variable\`, blaming the user for a backend hole;"
  echo "\`bare\` means the backend has it on \`-rv --bare\` only, where the program is"
  echo "handed the machine instead of a host."
  echo
  echo "The interpreter has every one of these, and is not a column."
  echo
  echo "RV32I is the fifth backend and was missing from this table until"
  echo "v0.1.332 — a record whose job is to say which backend has which builtin,"
  echo "with a backend not in it. Most of its column is \`refused\`, which is the"
  echo "right answer for an integer-subset target that hands the program a"
  echo "machine rather than a host."
  echo
  echo "| builtin | C | LLVM | Wasm | RV32I |"
  echo "|---|:--:|:--:|:--:|:--:|"
  while IFS='|' read -r name prog; do
    [ -z "$name" ] && continue
    printf '%s\n' "$prog" > "$TMP/p.mere"
    c=$(classify -c "$TMP/p.mere")
    l=$(classify -ll "$TMP/p.mere")
    w=$(classify -w "$TMP/p.mere")
    r=$(classify -rv "$TMP/p.mere")
    printf '| `%s` | %s | %s | %s | %s |\n' "$name" "$c" "$l" "$w" "$r"
  done < "$TMP/cases"
} > "$TMP/matrix.md"

missing=$(grep -c '^| `.*MISSING' "$TMP/matrix.md" || true)
errors=$(grep -c '^| `.*| error' "$TMP/matrix.md" || true)

if [ "$UPDATE" = 1 ]; then
  cp "$TMP/matrix.md" "$OUT"
  echo "host_matrix: wrote $OUT"
  echo "             $gen_summary"
  [ "$missing" != 0 ] && echo "host_matrix: $missing row(s) still say MISSING — those are backend holes reported as user typos"
  nc=$(grep -c '^| `.*nocompile' "$OUT" || true)
  [ "$nc" != 0 ] && echo "host_matrix: $nc row(s) say nocompile — emitted and then rejected by the C compiler"
  exit 0
fi

if [ ! -f "$OUT" ]; then
  echo "host_matrix: $OUT is missing — run with --update" >&2
  exit 1
fi

if diff -u "$OUT" "$TMP/matrix.md" > "$TMP/diff"; then
  # A bare backtick, matching the two greps above. With a backslash before it
  # this counted 50 on BSD grep and 0 on GNU grep, where `\`` is an extension
  # meaning "start of buffer" — so CI reported "ok (0 builtins)" for a run that
  # had in fact classified every one of them. The diff above is the real check
  # and it was passing; it was the summary line that lied, which is worse than
  # it sounds: "0 checked" is exactly what a gate that did not run looks like.
  nocompile=$(grep -c '^| `.*nocompile' "$OUT" || true)
  bare=$(grep -c '^| `.*| bare' "$OUT" || true)
  echo "host_matrix: ok  ($(grep -c '^| `' "$OUT") builtins, $missing MISSING, $nocompile nocompile, $bare bare-only, $errors error)"
  echo "             $gen_summary"
  [ "$dropped" != 0 ] && echo "             $dropped synthesized probe(s) did not type-check, dropped"
  true
  exit 0
fi

echo "host_matrix: FAILED — the matrix changed" >&2
cat "$TMP/diff" >&2
echo "Run 'sh scripts/host_matrix.sh --update' if the change is intended." >&2
exit 1

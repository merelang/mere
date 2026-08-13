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
#   yes       the backend emitted code
#   refused   the backend said it has no lowering — loud, and fine
#   MISSING   "unbound variable" — the compiler blamed the user for a backend hole
#   error     anything else (shown, so it can be looked at)
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

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# name|a program that uses it. One line each, and each has to type-check: the point is
# to reach codegen, so anything the typer rejects would measure nothing.
cat > "$TMP/cases" <<'CASES'
print|let _ = print "x"; 0
print_no_nl|let _ = print_no_nl "x"; 0
print_err|let _ = print_err "x"; 0
print_int|let _ = print_int 1; 0
print_bool|let _ = print_bool true; 0
print_bytes|let _ = print_bytes (bytes_of_str "x"); 0
read_file|let s = read_file "/dev/null"; str_len s
write_file|let _ = write_file "/dev/null" "x"; 0
read_file_bytes|let v = read_file_bytes "/dev/null"; vec_len v
write_file_bytes|let _ = write_file_bytes "/dev/null" (vec_new ()); 0
read_bytes|let b = read_bytes "/dev/null"; bytes_len b
write_bytes|let _ = write_bytes "/dev/null" (bytes_of_str "x"); 0
read_line|let s = read_line (); str_len s
read_stdin|let s = read_stdin (); str_len s
read_lines|let xs = read_lines "/dev/null"; 0
read_key|let k = read_key (); k
tty_raw|let _ = tty_raw (); 0
tty_restore|let _ = tty_restore (); 0
args|let xs = args (); 0
run|let n = run "true"; n
env_var|let e = env_var "HOME"; 0
exit|let _ = print "x"; let _ = exit 0; 0
file_exists|let b = file_exists "/dev/null"; if b then 1 else 0
file_mtime|let t = file_mtime "/dev/null"; 0
file_size|let n = file_size "/dev/null"; n
list_dir|let xs = list_dir "/tmp"; 0
mkdir_p|let _ = mkdir_p "/tmp/mere_probe"; 0
sleep_ms|let _ = sleep_ms 1; 0
time|let t = time (); 0
random_int|let n = random_int 10; n
random_float|let f = random_float (); 0
str_of_float|let s = str_of_float 1.5; str_len s
float_of_str|let f = float_of_str "1.5"; 0
spawn|let _ = spawn (fn () -> ()); 0
join|let h = spawn (fn () -> ()); let _ = join h; 0
detach|let h = spawn (fn () -> ()); let _ = detach h; 0
channel_new|let c = channel_new (); let _ = channel_send c 1; 0
channel_send|let c = channel_new (); let _ = channel_send c 1; 0
channel_recv|let c = channel_new (); let _ = channel_send c 1; let v = channel_recv c; v
channel_close|let c = channel_new (); let _ = channel_send c 1; let _ = channel_close c; 0
channel_recv_opt|let c = channel_new (); let _ = channel_send c 1; let _ = channel_recv_opt c; 0
channel_recv_timeout|let c = channel_new (); let _ = channel_send c 1; let _ = channel_recv_timeout c 10; 0
par_map|let xs = par_map (fn (x: int) -> x + 1) (Cons (1, Nil)); 0
file_open|let f = file_open "/dev/null"; let _ = file_close f; 0
file_read_line|let f = file_open "/dev/null"; let s = file_read_line f; 0
file_openrw|let f = file_openrw "/tmp/mere_probe.bin"; let _ = file_close f; 0
file_fsync|let f = file_openrw "/tmp/mere_probe.bin"; let _ = file_fsync f; 0
file_pread|let f = file_open "/dev/null"; let v = file_pread f 0 4; vec_len v
file_pwrite|let f = file_openrw "/tmp/mere_probe.bin"; let n = file_pwrite f 0 (vec_new ()); n
file_pwrite_bytes|let f = file_openrw "/tmp/mere_probe.bin"; let n = file_pwrite_bytes f 0 (bytes_of_str "x"); n
CASES

classify() {  # classify <flag> <file>
  if "$MERE" "$1" "$2" >/dev/null 2>"$TMP/err"; then
    echo yes
  elif grep -q 'unbound variable' "$TMP/err"; then
    echo MISSING
  elif grep -qE 'no (LLVM|Wasm) lowering|unsupported' "$TMP/err"; then
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
  echo "fails with \`unbound variable\`, blaming the user for a backend hole."
  echo
  echo "The interpreter has every one of these, and is not a column."
  echo
  echo "| builtin | C | LLVM | Wasm |"
  echo "|---|:--:|:--:|:--:|"
  while IFS='|' read -r name prog; do
    [ -z "$name" ] && continue
    printf '%s\n' "$prog" > "$TMP/p.mere"
    c=$(classify -c "$TMP/p.mere")
    l=$(classify -ll "$TMP/p.mere")
    w=$(classify -w "$TMP/p.mere")
    printf '| `%s` | %s | %s | %s |\n' "$name" "$c" "$l" "$w"
  done < "$TMP/cases"
} > "$TMP/matrix.md"

missing=$(grep -c '^| `.*MISSING' "$TMP/matrix.md" || true)
errors=$(grep -c '^| `.*| error' "$TMP/matrix.md" || true)

if [ "$UPDATE" = 1 ]; then
  cp "$TMP/matrix.md" "$OUT"
  echo "host_matrix: wrote $OUT"
  [ "$missing" != 0 ] && echo "host_matrix: $missing row(s) still say MISSING — those are backend holes reported as user typos"
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
  echo "host_matrix: ok  ($(grep -c '^| `' "$OUT") builtins, $missing MISSING, $errors error)"
  exit 0
fi

echo "host_matrix: FAILED — the matrix changed" >&2
cat "$TMP/diff" >&2
echo "Run 'sh scripts/host_matrix.sh --update' if the change is intended." >&2
exit 1

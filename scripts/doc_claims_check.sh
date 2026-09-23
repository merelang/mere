#!/bin/sh
# scripts/doc_claims_check.sh — a documented limitation is still a limitation.
#
# WHY THIS GATE EXISTS. Three sentences in the hand-written docs described a
# compiler that had not existed for a long time. `fail` on Wasm was documented
# as not unwinding, 237 releases after v0.1.272 taught it to; the Wasm host was
# documented as having one output sink, after v0.1.503 gave it `print_err`; and
# a top-level `while` was documented as codegen-unsupported although it compiles
# on three backends and runs. Every one of those fixes shipped WITH a gate --
# `region_fail_unwind.mere`, `echo_check.sh`, the parity suite -- and every gate
# was green while the prose next to it was false. A gate proves the compiler;
# nothing was reading the sentences.
#
# WHAT IS CHECKED. A catalogue of claims. Each row names a doc, a phrase that
# must appear in it, and a question to put to THIS compiler:
#
#   refuse  the program must NOT be accepted   (the limitation still holds)
#   accept  the program MUST be accepted       (the capability still works)
#   absent  the program runs and its output must not contain a string
#   present the program runs and its output must contain one
#   exists  a path the doc names must be on disk
#
# ⚠ A PHRASE MUST FIT ON ONE LINE. The check is a fixed-string grep, and a
# doc wraps where it likes -- the first row added after this note was written
# across a line break and reported PHRASE GONE from a file that said exactly
# what it claimed.
#
# A row goes red in both directions: the phrase disappearing from the doc means
# the claim moved or was reworded without this catalogue hearing about it, and
# the probe answering the other way means the doc is now false. The report names
# the file and the line so the fix is an edit, not a search.
#
# A SECOND LIST: retired wordings. A claim that stops being true usually has
# more than one copy -- the `while` sentence had two, in different files -- so
# retiring it means saying the old words out loud once and refusing them
# everywhere in the hand-written docs from then on.
#
# WHAT IT DOES NOT CHECK, said plainly. Only what is in the catalogue. The
# hand-written docs contain about 160 negative claims; eight are here. This gate
# cannot tell you that an unlisted sentence went stale, and a row proves nothing
# about the paragraph around it. It is the same trade `doc_coverage_check.sh`
# makes one layer down -- that one asks whether a builtin's NAME is spelled
# anywhere, this one asks whether a CLAIM is still true, and neither asks whether
# the surrounding explanation is any good.
#
# Usage:
#   sh scripts/doc_claims_check.sh            # check
#   sh scripts/doc_claims_check.sh --poison   # check that it can go red
set -u

M="${M:-./_build/default/bin/mere.exe}"
[ -x "$M" ] || { echo "doc_claims: $M is missing (dune build?)" >&2; exit 2; }

rows() {
  cat <<'ROWS'
docs/language-reference.md|encoded as UTF-8|accept|unicode_escape
docs/language-reference.md|Binary and octal literals|accept|binary_literal
docs/language-reference.md|may be written between digits|accept|digit_separator
docs/language-reference.md|A surrogate half|refuse|surrogate_escape
docs/language-reference.md|a file that marks nothing exports|accept|file_pub_optin
docs/language-reference.md|No nested string literals in interpolation|refuse|nested_interp
docs/language-reference.md|A type name may not be declared twice with different constructors|refuse|type_redecl
docs/language-reference.md|A top-level `while` must be bound or be the last expression|accept|toplevel_while
docs/stdlib-reference.md|What the handler receives is the diagnostic line|present|try_or_reason
docs/stdlib-reference.md|test/parity/region_fail_unwind.mere|exists|test/parity/region_fail_unwind.mere
docs/stdlib-reference.md|test/parity/shift_counts.mere|exists|test/parity/shift_counts.mere
docs/stdlib-reference.md|test/parity/int_width_boundary.mere|exists|test/parity/int_width_boundary.mere
ROWS
}

# Wordings that were RETIRED, and must not survive anywhere in the hand-written
# docs. This is the half of today's failure the catalogue above cannot see: the
# `while` claim had a SECOND copy in patterns.md, and fixing the first one left
# the reader a file that still said the old thing. A phrase retires here on the
# day its claim stops being true.
#
# The quotations a fixed entry makes of its own old wording ("this entry said X
# long after it stopped being true") are deliberately not these strings -- a
# retired phrase is the full assertive sentence, not the fragment quoted back.
retired() {
  cat <<'RETIRED'
Wasm has one output sink
`fail` on Wasm does not unwind
the language can observe that something failed, not why
No Unicode escape
no octal or binary literal syntax and no digit separator
File-level visibility has nothing to enforce
codegen support only inside fn bodies
`while` only inside fn bodies
RETIRED
}

# Hand-written docs only. changelog.md is history: a retired sentence SHOULD
# still be there, in the entry that retired it.
hand_written_docs() {
  for f in "$1"/docs/*.md "$1"/README.md; do
    case "$f" in *changelog.md) continue ;; esac
    [ -f "$f" ] && echo "$f"
  done
}

check_retired() {
  n=0
  while IFS= read -r phrase; do
    [ -n "${phrase:-}" ] || continue
    for f in $(hand_written_docs "$1"); do
      line=$(grep -nF -- "$phrase" "$f" | head -1 | cut -d: -f1)
      [ -n "$line" ] || continue
      echo "  RETIRED WORDING  ${f#$1/}:$line — \"$phrase\""
      n=$((n + 1))
    done
  done <<EOF
$(retired)
EOF
  return $n
}

# One probe per name. printf rather than a here-doc: these programs are mostly
# quotes and backslashes, and a here-doc would need every one of them escaped
# a second time.
write_probe() {
  case "$1" in
    unicode_escape)   printf 'print "\\u0041"\n' > "$2" ;;
    surrogate_escape) printf 'print "\\uD800"\n' > "$2" ;;
    file_pub_optin)   printf 'let helper = fn (n: int) -> n * 2;\nprint_int (helper 21)\n' > "$2" ;;
    binary_literal)   printf 'print_int 0b1010\n' > "$2" ;;
    digit_separator)  printf 'print_int 1_000\n' > "$2" ;;
    nested_interp)    printf 'print "x = {show \\"abc\\"}"\n' > "$2" ;;
    type_redecl)      printf 'type t = A | B;\ntype t = C | D;\nprint_int 0\n' > "$2" ;;
    toplevel_while)   printf 'let v = vec_new ();\nlet _ = vec_push v 0;\nlet _ = while vec_len v < 5 do vec_push v (vec_len v);\nprint_int (vec_len v)\n' > "$2" ;;
    try_or_reason)    printf 'let r = try_or_msg (fn () -> fail "REASON_XYZ") (fn (m: str) -> m) in\nprint r\n' > "$2" ;;
    *) return 1 ;;
  esac
}

# The control every `refuse` row needs: a program that is accepted. If this one
# is refused the compiler is broken in some other way, and every `refuse` row
# below would pass for the wrong reason.
control_ok() {
  printf 'let _ = "a\\tb" in print_int 0xFF\n' > "$T/control.mere"
  "$M" check "$T/control.mere" >/dev/null 2>&1
}

run_rows() {
  docroot="$1"; fails=0; checked=0
  while IFS='|' read -r doc phrase kind arg; do
    [ -n "${doc:-}" ] || continue
    checked=$((checked + 1))
    f="$docroot/$doc"
    if [ ! -f "$f" ]; then
      echo "  MISSING DOC  $doc"; fails=$((fails + 1)); continue
    fi
    line=$(grep -nF -- "$phrase" "$f" | head -1 | cut -d: -f1)
    if [ -z "$line" ]; then
      echo "  PHRASE GONE  $doc — \"$phrase\""
      fails=$((fails + 1)); continue
    fi
    case "$kind" in
      refuse)
        write_probe "$arg" "$T/p.mere" || { echo "  NO PROBE  $arg"; fails=$((fails+1)); continue; }
        if "$M" check "$T/p.mere" >/dev/null 2>&1; then
          echo "  STALE  $doc:$line — the program it calls impossible is accepted ($arg)"
          fails=$((fails + 1))
        fi ;;
      accept)
        write_probe "$arg" "$T/p.mere" || { echo "  NO PROBE  $arg"; fails=$((fails+1)); continue; }
        if ! "$M" check "$T/p.mere" >/dev/null 2>&1; then
          echo "  STALE  $doc:$line — the program it calls fine is refused ($arg)"
          fails=$((fails + 1))
        fi ;;
      absent)
        write_probe "$arg" "$T/p.mere" || { echo "  NO PROBE  $arg"; fails=$((fails+1)); continue; }
        out=$("$M" "$T/p.mere" 2>&1)
        case "$out" in
          *REASON_XYZ*)
            echo "  STALE  $doc:$line — the reason it says is unreachable came back ($arg)"
            fails=$((fails + 1)) ;;
        esac ;;
      present)
        write_probe "$arg" "$T/p.mere" || { echo "  NO PROBE  $arg"; fails=$((fails+1)); continue; }
        out=$("$M" "$T/p.mere" 2>&1)
        case "$out" in
          *REASON_XYZ*) ;;
          *)
            echo "  STALE  $doc:$line — the reason it says arrives did not ($arg)"
            fails=$((fails + 1)) ;;
        esac ;;
      exists)
        [ -e "$arg" ] || {
          echo "  STALE  $doc:$line — names a path that is not here ($arg)"
          fails=$((fails + 1)); } ;;
      *) echo "  BAD KIND  $kind"; fails=$((fails + 1)) ;;
    esac
  done <<EOF
$(rows)
EOF
  check_retired "$docroot" || fails=$((fails + $?))
  echo "$checked claims checked, $fails stale" > "$T/summary"
  return $fails
}

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
control_ok || { echo "doc_claims: the control program does not compile (cannot answer)" >&2; exit 2; }

if [ "${1:-}" = "--poison" ]; then
  pfail=0
  # 1. a phrase removed from a copy of the docs must be reported.
  P="$T/poison1"; mkdir -p "$P/docs"; cp docs/*.md "$P/docs/"
  # ⚠ The phrase this deletes has to be one the CATALOGUE names. It used to be
  # "No Unicode escape", which stopped being a row the day the escape landed --
  # and the poison then passed a file it had not changed, which is the poison
  # equivalent of a stale pin.
  grep -vF -- "A surrogate half" "$P/docs/language-reference.md" > "$P/tmp" \
    && cat "$P/tmp" > "$P/docs/language-reference.md"
  if run_rows "$P" >/dev/null 2>&1; then
    echo "doc_claims --poison 1: FAILED (a deleted phrase went unnoticed)"; pfail=1
  else
    echo "doc_claims --poison 1: ok (a deleted phrase is reported)"
  fi
  # 2. a `refuse` row whose program starts compiling must be reported. Swap the
  #    probe for one that is ordinary Mere, which is what "the limitation lifted"
  #    looks like from here.
  write_probe() { printf 'print_int 1\n' > "$2"; }
  if run_rows "." >/dev/null 2>&1; then
    echo "doc_claims --poison 2: FAILED (a lifted limitation went unnoticed)"; pfail=1
  else
    echo "doc_claims --poison 2: ok (a lifted limitation is reported)"
  fi
  # 3. a retired wording put back into a copy of the docs must be reported. This
  #    is the second copy that outlived the first fix.
  P3="$T/poison3"; mkdir -p "$P3/docs"; cp docs/*.md "$P3/docs/"; cp README.md "$P3/"
  echo 'Note: `while` currently has codegen support only inside fn bodies.' \
    >> "$P3/docs/patterns.md"
  if check_retired "$P3" >/dev/null 2>&1; then
    echo "doc_claims --poison 3: FAILED (a revived wording went unnoticed)"; pfail=1
  else
    echo "doc_claims --poison 3: ok (a revived wording is reported)"
  fi
  exit $pfail
fi

if run_rows "."; then
  cat "$T/summary"
  exit 0
else
  cat "$T/summary"
  echo "doc_claims: the docs above describe a compiler this is not."
  exit 1
fi

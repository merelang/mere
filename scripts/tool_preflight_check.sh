#!/bin/sh
# scripts/tool_preflight_check.sh — a gate that did not run is not a gate that passed.
#
# WHY THIS EXISTS. 65 of this repo's gates exit 0 when a tool they need is
# absent, and 46 of those are wired into CI. That is the right behaviour for a
# developer without `psql` on their laptop, and it is the wrong behaviour for a
# build whose only report is red or green: the day a package is renamed, the
# install step fails, the gate skips, and CI stays green with the check gone.
#
# `qemu_virt.sh` is the clearest case. It is the differential against an
# emulator nobody here wrote -- the strongest oracle in the repo -- installed
# with `continue-on-error: true` and skipping cleanly when absent. Both halves
# are individually reasonable and together they mean the strongest check in the
# build could stop running without anything saying so.
#
# WHAT IT CHECKS. The tools are not a list somebody types here. They are
# DERIVED: every `command -v <tool>` in scripts/*.sh, mapped back to the gate
# that probes for it, and a tool is REQUIRED when at least one gate that probes
# for it is named in .github/workflows/ci.yml. A required tool that is absent
# is a gate that will silently not run, and this says which one.
#
# Locally it reports and exits 0 -- nobody needs psql to work on the parser.
# With --required (which CI passes) a missing tool is a failure.
#
# Usage:
#   sh scripts/tool_preflight_check.sh              # report
#   sh scripts/tool_preflight_check.sh --required   # CI: absent => red
#   sh scripts/tool_preflight_check.sh --poison     # the gate can still go red

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2
CI_YML="${TOOL_PREFLIGHT_CI_YML-.github/workflows/ci.yml}"
MODE="${1:-}"

# --poison: three ways this check could stop meaning anything, each asserted by
# the message it must print rather than by a non-zero exit.
if [ "$MODE" = "--poison" ]; then
  fails=0
  run() {
    label=$1; want=$2; shift 2
    out=$(env "$@" sh "$0" --required 2>&1)
    if [ $? -eq 0 ]; then
      echo "POISON NOT CAUGHT — $label"; fails=$((fails + 1)); return
    fi
    if printf '%s' "$out" | grep -qF "$want"; then echo "poison caught: $label"
    else
      echo "POISON CAUGHT FOR THE WRONG REASON — $label"
      echo "  wanted: $want"; printf '%s\n' "$out" | sed 's/^/  /'; fails=$((fails + 1))
    fi
  }
  # 1. the tool CI installs best-effort goes missing -- the case this exists for
  run "qemu-system-riscv32 disappears" \
    "ABSENT   qemu-system-riscv32" MERE_PREFLIGHT_FAKE_MISSING=qemu-system-riscv32
  # 2. the link from a gate to CI breaks, so nothing is required any more
  run "the denominator collapses" \
    "only 0 required tools were derived" TOOL_PREFLIGHT_CI_YML=/dev/null
  # 3. the floor itself -- proof that the count above is a real number
  run "the floor is a real number" \
    "required tools were derived" TOOL_PREFLIGHT_REQ_FLOOR=99
  [ "$fails" -eq 0 ] && { echo "tool_preflight --poison: 3 caught"; exit 0; }
  echo "tool_preflight --poison: $fails not caught"; exit 1
fi

# Tools that are allowed to be absent even in --required mode, each with the
# reason. ⚠ A name with no reason is a name nobody removes.
#   psql       the database gates run in their own CI job with a service
#              container; the gates job has no server and is not meant to.
#   sdl2-config  the audio gate needs a sound library that no CI runner has.
#   wasmtime / wasm-tools  the component-model gates are their own job.
#   mere       ⚠ NOT A DEPENDENCY. `command -v mere` is how three gates look
#              for the compiler when _build has none, and they exit 1 when
#              neither exists. Absence there is loud already; this derivation
#              cannot tell "probe that leads to a skip" from "probe that leads
#              to a failure", so the one false positive is named here.
ALLOWED_ABSENT="${TOOL_PREFLIGHT_ALLOWED-psql sdl2-config wasmtime wasm-tools mere}"

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

# tool<TAB>gate, one line per (tool, gate) pair.
#
# ⚠ THE FIRST VERSION MISSED THE GATE IT WAS WRITTEN FOR. `qemu_virt.sh` probes
# `command -v "$QEMU"`, and a derivation that only reads literal names sees a
# variable and moves on -- so qemu-system-riscv32, the tool whose silent
# absence is the whole argument, was not in the list. `$CC` (39 sites) and the
# loop variables went the same way. A one-line default is a name: the second
# pass resolves `VAR=${VAR:-tool}` and `VAR=tool` within the same file.
for f in scripts/*.sh; do
  g=$(basename "$f")
  {
    # 1. a literal name: command -v wat2wasm
    grep -ohE 'command -v "?[a-z][A-Za-z0-9_.-]*' "$f" 2>/dev/null \
      | sed 's/command -v "\{0,1\}//'

    # 2. a variable: command -v "$QEMU", resolved from VAR=${VAR:-tool} or VAR=tool
    grep -ohE 'command -v "?\$\{?[A-Z_][A-Z0-9_]*' "$f" 2>/dev/null \
      | sed -e 's/.*\$//' -e 's/^{//' | sort -u \
      | while read -r v; do
          line=$(grep -m1 -E "^[[:space:]]*$v=" "$f" 2>/dev/null)
          [ -n "$line" ] || continue
          case "$line" in
            *:-*) printf '%s\n' "$line" | sed 's/.*:-//; s/}.*//' | tr -d '\042\047' ;;
            *)    printf '%s\n' "$line" | sed 's/^[^=]*=//; s/[[:space:]].*//' | tr -d '\042\047' ;;
          esac
        done

    # 3. a loop variable: for t in clang wat2wasm node; do command -v "$t"
    grep -ohE 'command -v "?\$\{?[a-z][a-z0-9_]*' "$f" 2>/dev/null \
      | sed -e 's/.*\$//' -e 's/^{//' | sort -u \
      | while read -r v; do
          grep -m1 -E "^[[:space:]]*for $v in " "$f" 2>/dev/null \
            | sed "s/^[[:space:]]*for $v in //; s/;.*//" | tr ' ' '\n'
        done

    # 4. the same question behind a helper: have() { command -v "$1" ...; }
    # A comment is stripped first: the prose "have to" parsed as a tool named
    # `to`, which is what a shape-based scan gets for free.
    if grep -q 'command -v "\$1"' "$f" 2>/dev/null; then
      grep -v '^[[:space:]]*#' "$f" 2>/dev/null \
        | grep -ohE '(^|[;&|(]|[[:space:]])have [a-z][A-Za-z0-9_.-]*' | sed 's/.*have //'
    fi
  } | while read -r t; do
      case "$t" in
        ''|do|then|in|[0-9]*) continue ;;
        *[!A-Za-z0-9_.-]*) continue ;;
      esac
      printf '%s\t%s\n' "$t" "$g"
    done
done | sort -u > "$tmp/pairs"

[ -s "$tmp/pairs" ] || {
  echo "tool_preflight: FAIL — no (tool, gate) pairs were derived."
  echo "  The gates stopped spelling their probes as \`command -v <tool>\`, and"
  echo "  this check would pass for having nothing to check."
  exit 1; }

cut -f1 "$tmp/pairs" | sort -u > "$tmp/tools"
n_tools=$(wc -l < "$tmp/tools" | tr -d ' ')

# A tool is required when a gate that probes for it is named in CI.
: > "$tmp/required"; : > "$tmp/local_only"
while read -r t; do
  in_ci=""
  for g in $(awk -F'\t' -v t="$t" '$1 == t { print $2 }' "$tmp/pairs"); do
    grep -q "scripts/$g" "$CI_YML" && { in_ci="$g"; break; }
  done
  if [ -n "$in_ci" ]; then printf '%s\t%s\n' "$t" "$in_ci" >> "$tmp/required"
  else printf '%s\n' "$t" >> "$tmp/local_only"; fi
done < "$tmp/tools"

fake="${MERE_PREFLIGHT_FAKE_MISSING-}"
missing=0
echo "tool_preflight: $n_tools tools named by $(cut -f2 "$tmp/pairs" | sort -u | wc -l | tr -d ' ') gates"
while IFS="$(printf '\t')" read -r t g; do
  [ -n "$t" ] || continue
  case " $ALLOWED_ABSENT " in *" $t "*) echo "  skip-ok  $t (absent is allowed: see ALLOWED_ABSENT)"; continue ;; esac
  if [ "$t" = "$fake" ] || ! command -v "$t" >/dev/null 2>&1; then
    echo "  ABSENT   $t — scripts/$g would skip, and CI names it"
    missing=$((missing + 1))
  fi
done < "$tmp/required"

req=$(wc -l < "$tmp/required" | tr -d ' ')
echo "  $req of them are needed by a gate CI runs; $missing absent"

# ⚠ A FLOOR, because the first version of this script printed "0 of them are
# needed by a gate CI runs" and called itself ok. The derivation had silently
# produced nothing -- which is the failure this whole file is about, written
# into the file about it.
REQ_FLOOR="${TOOL_PREFLIGHT_REQ_FLOOR-8}"
[ "$req" -ge "$REQ_FLOOR" ] || {
  echo "tool_preflight: FAIL — only $req required tools were derived (floor $REQ_FLOOR)."
  echo "  The mapping from a gate to the tools it probes for, or from a gate to"
  echo "  CI, stopped working. An empty denominator makes every absent tool invisible."
  exit 1; }

if [ "$MODE" = "--required" ] || [ "${MERE_REQUIRE_TOOLS-}" = "1" ]; then
  [ "$missing" -eq 0 ] || {
    echo "tool_preflight: FAIL — $missing tool(s) absent, so that many CI gates would"
    echo "  report nothing and the build would stay green. Install them, or add the"
    echo "  name to ALLOWED_ABSENT with the reason it is allowed to be missing."
    exit 1; }
  echo "tool_preflight: ok (required mode)"
  exit 0
fi
echo "tool_preflight: ok (report only — pass --required to make an absent tool fatal)"
exit 0

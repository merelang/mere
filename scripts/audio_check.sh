#!/bin/sh
# scripts/audio_check.sh — the audio queue's contract, with no speakers.
#
# Compiles test/audio/audio_probe.mere and runs it under the SDL dummy audio
# driver: open reports a device, an empty queue reads 0, queued bytes are
# visible, the queue drains to exactly 0 in bounded time, a closed device
# answers -1, a nonsense rate answers -1. Sample CORRECTNESS is deliberately
# not claimed here — the dummy driver eats the bytes, and what they should
# be is the consumer's oracle to hold (msynth checks its PCM against an
# independently computed expectation). Skips when SDL2 is not installed.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
CC="${CC:-cc}"
[ -x "$MERE" ] || { echo "audio_check: $MERE not found — run 'dune build'" >&2; exit 1; }
command -v "$CC" >/dev/null 2>&1 || { echo "audio_check: no C compiler" >&2; exit 0; }
command -v sdl2-config >/dev/null 2>&1 || { echo "audio_check: no sdl2-config — skipping" >&2; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

"$MERE" -c "$ROOT/test/audio/audio_probe.mere" > "$TMP/p.c" 2>"$TMP/p.err" \
  || { echo "FAIL audio: mere -c refused the probe"; cat "$TMP/p.err"; exit 1; }
# -lm explicitly: the probe's sine generator needs libm, which macOS bundles
# into libSystem but Linux does not — this line was the first thing this gate
# did on a Linux runner, and it turned CI red from v0.1.314 to v0.1.316 while
# every gate wired in after it went unrun (a red build stops at the first
# failed step; everything downstream is unknown, not green).
"$CC" -O1 -w "$TMP/p.c" $(sdl2-config --cflags --libs) -lm -o "$TMP/p" 2>"$TMP/cc.err" \
  || { echo "FAIL audio: C compile failed"; cat "$TMP/cc.err"; exit 1; }

SDL_AUDIODRIVER=dummy sh "$ROOT/scripts/bounded.sh" 30 "$TMP/p" > "$TMP/got" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL audio: probe exited $rc"; cat "$TMP/got"; exit 1; }

cat > "$TMP/want" <<'W'
open=ok
empty=0
queued>0
drained=0
close=0
after_close=-1
badrate=-1
()
W
diff -u "$TMP/want" "$TMP/got" || { echo "FAIL audio: transcript differs"; exit 1; }
echo "audio_check: ok"

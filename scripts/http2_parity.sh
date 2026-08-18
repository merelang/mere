#!/bin/sh
# scripts/http2_parity.sh — check contrib/http2/frame.mere against hyperframe.
#
# Why hyperframe: HTTP/2's frame layout is a transcription — a 24-bit length, a
# type, flags, a 31-bit stream identifier with one reserved bit, all big-endian.
# Every one of those is a fact somebody read out of RFC 9113 and typed in, and the
# only check that catches a mis-transcription is byte equality with an
# implementation somebody else wrote from the same document. hyperframe is that
# implementation, and it is the frame layer of the h2 library that real Python
# HTTP/2 clients and servers use.
#
# A SECOND, INDEPENDENT CONFIRMATION exists for one of these bytes and is worth
# recording: an empty SETTINGS frame serialises as `000000040000000000`, and that
# is byte-for-byte what grpcurl 1.8.8 was observed to send on a real connection.
# Two implementations that never met agree, which is the only kind of agreement
# that means anything.
#
# THREE SECTIONS:
#
#   1. encode  — build each frame in Mere, compare hex with hyperframe's
#   2. decode  — hyperframe serialises, we parse, compare the FIELDS
#   3. grpc    — the gRPC message prefix, pinned to what a real client sent
#
# The sweep crosses frame type × flags × stream id × payload size rather than
# listing frames somebody thought of, and it deliberately includes a stream id
# with the reserved bit set — the case a decoder that reads 32 bits gets wrong
# against every well-behaved peer and only wrong against a hostile one.
#
# Skips (exit 0) when hyperframe is absent, so it stays out of the build's
# dependency set.
#
# Usage:
#   sh scripts/http2_parity.sh

set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MERE="$ROOT/_build/default/bin/mere.exe"

[ -x "$MERE" ] || { echo "http2_parity: $MERE not found — run 'dune build'" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "http2_parity: python3 absent, skipping"; exit 0; }
if ! python3 -c "import hyperframe" 2>/dev/null; then
  echo "http2_parity: the 'hyperframe' package is not importable, skipping"
  echo "              (python3 -m pip install hyperframe)"
  exit 0
fi
HF_VER=$(python3 -c "import hyperframe; print(hyperframe.__version__)")
echo "http2_parity: oracle is hyperframe $HF_VER (python $(python3 -c 'import sys;print(".".join(map(str,sys.version_info[:3])))'))"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; rm -f "$ROOT/examples/.http2_parity_tmp.mere"' EXIT
fail=0

# Same discipline as graphql_parity: `set -e` is right for the preflight and
# wrong for the sections, each of which records its own verdict. A crash in the
# subject must name a section, not end the run and print nothing.
set +e

run_subject() {  # run_subject <label> <mere-file> <stdout-file>
  if ( ulimit -t 240; "$MERE" "$2" ) > "$3" 2> "$TMP/err.txt"; then return 0; fi
  echo "  FAIL  $1  the subject itself failed on this section:"
  sed 's/^/          /' "$TMP/err.txt" | head -4
  fail=1
  return 1
}

# --- the sweep, generated on the oracle's side ----------------------------
# Each line is: label <TAB> expected-hex <TAB> mere-expression
python3 - "$TMP" <<'PY'
import sys, pathlib
from hyperframe.frame import (
    DataFrame, HeadersFrame, SettingsFrame, WindowUpdateFrame, RstStreamFrame,
    PingFrame, GoAwayFrame, ContinuationFrame,
)
rows = []
def add(label, frame, expr):
    rows.append((label, frame.serialize().hex(), expr))

def h(b):  # bytes -> a Mere `bytes` expression
    return 'bytes_of_hex "%s"' % b.hex()

# DATA: payload size crosses every length-encoding boundary, and END_STREAM.
for n in (0, 1, 2, 255, 256, 16383, 16384):
    body = bytes((i % 251 for i in range(n)))
    for flags, mflags in ((set(), "0"), ({"END_STREAM"}, "H2.end_stream")):
        f = DataFrame(1, data=body); f.flags = flags
        add(f"DATA n={n} flags={mflags}", f,
            f"H2.frame_bytes H2.data {mflags} 1 ({h(body)})")

# HEADERS: END_HEADERS and END_STREAM, together and apart.
for flags, mflags in ((set(), "0"), ({"END_HEADERS"}, "H2.end_headers"),
                      ({"END_STREAM"}, "H2.end_stream"),
                      ({"END_HEADERS", "END_STREAM"},
                       "(bit_or H2.end_headers H2.end_stream)")):
    f = HeadersFrame(1, data=b"\x82\x86"); f.flags = flags
    add(f"HEADERS flags={mflags}", f,
        f'H2.frame_bytes H2.headers {mflags} 1 ({h(b"\x82\x86")})')

# SETTINGS: empty, ACK, and several identifier/value pairs including the maximum
# 32-bit value — the one a signed shift gets wrong.
add("SETTINGS empty", SettingsFrame(0),
    "H2.frame_bytes H2.settings 0 0 (H2.settings_payload [])")
fa = SettingsFrame(0); fa.flags = {"ACK"}
add("SETTINGS ack", fa, "H2.frame_bytes H2.settings H2.ack 0 (H2.settings_payload [])")
for kvs in ({3: 100}, {4: 65535}, {1: 4096, 3: 250, 4: 1048576},
            {5: 16777215}, {2: 0}, {6: 4294967295}):
    mere = "[" + ", ".join(f"({k}, {v})" for k, v in kvs.items()) + "]"
    add(f"SETTINGS {kvs}", SettingsFrame(0, settings=dict(kvs)),
        f"H2.frame_bytes H2.settings 0 0 (H2.settings_payload {mere})")

# WINDOW_UPDATE: connection level and stream level, at the extremes.
for stream in (0, 1, 2147483647):
    for inc in (1, 65535, 2147483647):
        add(f"WINDOW_UPDATE s={stream} inc={inc}",
            WindowUpdateFrame(stream, window_increment=inc),
            f"H2.frame_bytes H2.window_update 0 {stream} (H2.u32_payload {inc})")

# RST_STREAM: every error code the RFC names, plus the top of the range.
for err in (0, 1, 2, 8, 11, 13, 4294967295):
    add(f"RST_STREAM err={err}", RstStreamFrame(1, error_code=err),
        f"H2.frame_bytes H2.rst_stream 0 1 (H2.u32_payload {err})")

# PING: exactly eight bytes of opaque data, and its ACK.
for data, flags, mflags in ((b"\x00" * 8, set(), "0"),
                            (b"12345678", set(), "0"),
                            (b"\xff" * 8, {"ACK"}, "H2.ack")):
    f = PingFrame(0, opaque_data=data); f.flags = flags
    add(f"PING {data!r} flags={mflags}", f,
        f"H2.frame_bytes H2.ping {mflags} 0 ({h(data)})")

# GOAWAY: last stream id, error code, and optional debug data.
for last, err, dbg in ((0, 0, b""), (1, 1, b""), (2147483647, 11, b"why"),
                       (5, 4294967295, b"\x00\x01")):
    add(f"GOAWAY last={last} err={err} dbg={dbg!r}",
        GoAwayFrame(0, last_stream_id=last, error_code=err, additional_data=dbg),
        f"H2.frame_bytes H2.goaway 0 0 (H2.goaway_payload {last} {err} ({h(dbg)}))")

# CONTINUATION.
fc = ContinuationFrame(1, data=b"\x40\x02ab"); fc.flags = {"END_HEADERS"}
add("CONTINUATION end_headers", fc,
    f'H2.frame_bytes H2.continuation H2.end_headers 1 ({h(b"\x40\x02ab")})')

tmp = pathlib.Path(sys.argv[1])
tmp.joinpath("want.txt").write_text("\n".join(r[1] for r in rows) + "\n")
tmp.joinpath("labels.txt").write_text("\n".join(r[0] for r in rows) + "\n")
tmp.joinpath("exprs.txt").write_text("\n".join(r[2] for r in rows) + "\n")
print(len(rows))
PY
NROWS=$(wc -l < "$TMP/want.txt" | tr -d ' ')

# --- 1. encode -----------------------------------------------------------
{
  echo 'import "../contrib/http2/frame.mere";'
  while IFS= read -r expr; do
    [ -z "$expr" ] && continue
    printf 'let _ = print (hex_of_bytes (%s));\n' "$expr"
  done < "$TMP/exprs.txt"
  echo '0'
} > "$ROOT/examples/.http2_parity_tmp.mere"

if run_subject "encode" "$ROOT/examples/.http2_parity_tmp.mere" "$TMP/enc_raw.txt"; then
  sed '$d' "$TMP/enc_raw.txt" > "$TMP/enc.txt"
  if diff -q "$TMP/want.txt" "$TMP/enc.txt" >/dev/null; then
    echo "  ok    encode  $NROWS frames byte-identical to hyperframe"
  else
    echo "  FAIL  encode"
    paste -d'|' "$TMP/labels.txt" "$TMP/want.txt" "$TMP/enc.txt" \
      | awk -F'|' '$2 != $3 { printf "        %-34s oracle=%s\n                                   ours=  %s\n", $1, $2, $3 }' \
      | head -18
    fail=1
  fi
fi

# --- 2. decode -----------------------------------------------------------
# The same frames, read back. The comparison is on the FIELDS, so a decoder that
# happens to produce the right bytes for the wrong reasons is still caught.
python3 - "$TMP" <<'PY'
import sys, pathlib
from hyperframe.frame import Frame
tmp = pathlib.Path(sys.argv[1])
out = []
for hexs in tmp.joinpath("want.txt").read_text().split("\n"):
    if not hexs: continue
    raw = bytes.fromhex(hexs)
    f, ln = Frame.parse_frame_header(memoryview(raw[:9]))
    # type, flags byte, stream, payload length — the four header fields, as the
    # oracle understands them. The flags byte is recovered from the raw header
    # because hyperframe exposes flags as names.
    out.append(f"{raw[3]} {raw[4]} {f.stream_id} {ln}")
tmp.joinpath("dec_want.txt").write_text("\n".join(out) + "\n")
PY

{
  echo 'import "../contrib/http2/frame.mere";'
  echo 'let show = fn (h: str) ->'
  echo '  let (ln, ty, fl, st, _, _) = H2.read_frame (bytes_of_hex h) 0 in'
  echo '  print (str_of_int ty ++ " " ++ str_of_int fl ++ " " ++ str_of_int st'
  echo '         ++ " " ++ str_of_int ln);'
  while IFS= read -r hexs; do
    [ -z "$hexs" ] && continue
    printf 'let _ = show "%s";\n' "$hexs"
  done < "$TMP/want.txt"
  echo '0'
} > "$ROOT/examples/.http2_parity_tmp.mere"

if run_subject "decode" "$ROOT/examples/.http2_parity_tmp.mere" "$TMP/dec_raw.txt"; then
  sed '$d' "$TMP/dec_raw.txt" > "$TMP/dec.txt"
  if diff -q "$TMP/dec_want.txt" "$TMP/dec.txt" >/dev/null; then
    echo "  ok    decode  $NROWS frames: type / flags / stream / length agree"
  else
    echo "  FAIL  decode"
    paste -d'|' "$TMP/labels.txt" "$TMP/dec_want.txt" "$TMP/dec.txt" \
      | awk -F'|' '$2 != $3 { printf "        %-34s oracle=[%s] ours=[%s]\n", $1, $2, $3 }' \
      | head -12
    fail=1
  fi
fi

# --- 2b. the reserved bit ------------------------------------------------
# A stream identifier with the top bit set. Every well-behaved peer clears it, so
# a decoder that reads 32 bits is indistinguishable from a correct one until it
# meets a peer that does not — which is why this cannot be left to the sweep.
{
  echo 'import "../contrib/http2/frame.mere";'
  # 0-length SETTINGS on stream 0x80000001: the reserved bit set over stream 1.
  echo 'let (_, _, _, st, _, _) = H2.read_frame (bytes_of_hex "00000004000000000180000001" ) 0;'
  echo 'print (str_of_int st)'
} > "$ROOT/examples/.http2_parity_tmp.mere"
# The frame above is deliberately malformed in length; build a valid one instead.
python3 - "$TMP" <<'PY'
import sys, pathlib
raw = (0).to_bytes(3, "big") + bytes([4, 0]) + (0x80000001).to_bytes(4, "big")
pathlib.Path(sys.argv[1], "reserved.txt").write_text(raw.hex() + "\n")
PY
RES=$(cat "$TMP/reserved.txt")
{
  echo 'import "../contrib/http2/frame.mere";'
  printf 'let (_, _, _, st, _, _) = H2.read_frame (bytes_of_hex "%s") 0;\n' "$RES"
  echo 'print (str_of_int st)'
} > "$ROOT/examples/.http2_parity_tmp.mere"
if run_subject "reserved bit" "$ROOT/examples/.http2_parity_tmp.mere" "$TMP/res_out.txt"; then
  got=$(sed '$d' "$TMP/res_out.txt" | head -1)
  if [ "$got" = 1 ]; then
    echo "  ok    reserved bit  a stream id of 0x80000001 reads as 1, not 2147483649"
  else
    echo "  FAIL  reserved bit  0x80000001 read as $got, expected 1"
    echo "        the top bit of the stream identifier is reserved and must be ignored"
    fail=1
  fi
fi

# --- 2c. the writer's reserved bit --------------------------------------
# The sweep above uses stream ids 0, 1, 2 and 2147483647, all of which already
# have the reserved bit clear — so the mask in the WRITER is never exercised by
# it. Poisoning the writer to drop that mask did not turn this gate red, which
# means the guard was there without being checked.
#
# The RFC requires the bit to be sent as 0, so a caller handing over 0x80000001
# must produce the same frame as stream 1. The oracle is hyperframe's
# serialisation of stream 1 — hyperframe will not build the out-of-range one, and
# that refusal is itself the statement that only one of these is legal.
python3 - "$TMP" <<'PY2'
import sys, pathlib
from hyperframe.frame import RstStreamFrame
# RST_STREAM rather than SETTINGS: hyperframe refuses a SETTINGS frame on a
# non-zero stream, and it is right to — SETTINGS is a connection-level frame.
# That refusal is a useful reminder that "which streams may carry this type" is a
# rule of its own, and one this framing layer does not enforce.
pathlib.Path(sys.argv[1], "wres_want.txt").write_text(
    RstStreamFrame(1, error_code=0).serialize().hex() + "\n")
PY2
{
  echo 'import "../contrib/http2/frame.mere";'
  echo 'print (hex_of_bytes (H2.frame_bytes H2.rst_stream 0 2147483649 (H2.u32_payload 0)))'
} > "$ROOT/examples/.http2_parity_tmp.mere"
if run_subject "writer reserved bit" "$ROOT/examples/.http2_parity_tmp.mere" "$TMP/wres_out.txt"; then
  sed '$d' "$TMP/wres_out.txt" > "$TMP/wres.txt"
  if diff -q "$TMP/wres_want.txt" "$TMP/wres.txt" >/dev/null; then
    echo "  ok    writer reserved bit  stream 0x80000001 is written as stream 1"
  else
    echo "  FAIL  writer reserved bit"
    echo "        oracle (stream 1): $(cat "$TMP/wres_want.txt")"
    echo "        ours   (0x80000001): $(cat "$TMP/wres.txt")"
    fail=1
  fi
fi

# --- 2d. the PAYLOAD accessors ------------------------------------------
#
# Sections 1 and 2 cover the frame HEADER in both directions: type, flags, stream,
# length. Neither of them ever looks inside a payload, and that gap hid a real bug
# for as long as this file has existed.
#
# `H2.read_settings` read each entry's 32-bit value at offset i+4 instead of i+2 —
# two bytes past every six-byte entry, so the LAST entry of any payload read off
# the end. Nothing caught it because nothing CALLED it: the writer
# (`settings_payload`) had a parity section from the start, the reader was
# exported and documented and never fed a single byte, and the server's own
# comment said its peer's settings were "read and ignored". The first caller found
# it on the first connection.
#
# So this section exists for a reason that generalises past SETTINGS: AN EXPORT
# LIST IS NOT A COVERAGE LIST. Enumerating what `frame.mere` exports and counting
# call sites turned up a second accessor in the same state — `H2.error_code`, zero
# callers and zero coverage. It happens to be right. It was not checked.
python3 - "$TMP" <<'PY'
import sys, pathlib
from hyperframe.frame import (SettingsFrame, WindowUpdateFrame, RstStreamFrame,
                              Frame)

rows = []   # (label, mere-expression, expected-string)

# SETTINGS payloads, decoded to "id=value" in WIRE ORDER.
#
# Seven pairs is not arbitrary: it is what a python h2 client actually opens with,
# and 7 x 6 = 42 bytes is where the off-by-two first showed itself. One pair would
# also have caught it (the value would have read past a 6-byte payload), which is
# the measure of how untested this was.
settings_cases = [
    {},
    {4: 65535},
    {5: 16384},
    {1: 4096, 2: 0, 3: 100, 4: 65535, 5: 16384, 6: 4294967295},
    # The seven-pair opener, with a settings id we do not know (0x8 = ENABLE_CONNECT
    # PROTOCOL) present so the "ignore what you do not recognise" path is walked.
    {1: 4096, 2: 0, 3: 100, 4: 65535, 5: 16384, 6: 16384, 8: 1},
    # Maximum 32-bit values: the ones an arithmetic shift gets wrong.
    {4: 4294967295, 5: 4294967295},
]
for kvs in settings_cases:
    f = SettingsFrame(0, settings=dict(kvs))
    payload = f.serialize()[9:]
    want = " ".join(f"{k}={v}" for k, v in kvs.items())
    rows.append((f"SETTINGS {kvs}",
                 'str_join " " (list_map (H2.read_settings (bytes_of_hex "%s")) '
                 '(fn (kv) -> let (k, v) = kv in str_of_int k ++ "=" ++ str_of_int v))'
                 % payload.hex(),
                 want))

# WINDOW_UPDATE increments, including the reserved top bit set: it must be IGNORED
# on receipt, so 0x80000001 is an increment of 1.
for raw_inc, want in ((1, 1), (65535, 65535), (2147483647, 2147483647),
                      (0x80000001, 1)):
    payload = raw_inc.to_bytes(4, "big")
    rows.append((f"window_increment 0x{raw_inc:08x}",
                 'str_of_int (H2.window_increment (bytes_of_hex "%s"))' % payload.hex(),
                 str(want)))

# RST_STREAM error codes. The top bit is NOT reserved here — an error code is a
# full 32 bits — which is exactly the distinction a shared helper would erase.
for err in (0, 1, 2, 8, 11, 13, 2147483648, 4294967295):
    f = RstStreamFrame(1, error_code=err)
    payload = f.serialize()[9:]
    rows.append((f"error_code {err}",
                 'str_of_int (H2.error_code (bytes_of_hex "%s"))' % payload.hex(),
                 str(err)))

tmp = pathlib.Path(sys.argv[1])
tmp.joinpath("pay_labels.txt").write_text("\n".join(r[0] for r in rows) + "\n")
tmp.joinpath("pay_exprs.txt").write_text("\n".join(r[1] for r in rows) + "\n")
tmp.joinpath("pay_want.txt").write_text("\n".join(r[2] for r in rows) + "\n")
PY
NPAY=$(wc -l < "$TMP/pay_want.txt" | tr -d ' ')
{
  echo 'import "../contrib/http2/frame.mere";'
  while IFS= read -r expr; do
    [ -z "$expr" ] && continue
    printf 'let _ = print (%s);\n' "$expr"
  done < "$TMP/pay_exprs.txt"
  echo '0'
} > "$ROOT/examples/.http2_parity_tmp.mere"
if run_subject "payload accessors" "$ROOT/examples/.http2_parity_tmp.mere" "$TMP/pay_raw.txt"; then
  sed '$d' "$TMP/pay_raw.txt" > "$TMP/pay.txt"
  if diff -q "$TMP/pay_want.txt" "$TMP/pay.txt" >/dev/null; then
    echo "  ok    payload accessors  $NPAY cases: read_settings / window_increment / error_code"
  else
    echo "  FAIL  payload accessors"
    paste -d'|' "$TMP/pay_labels.txt" "$TMP/pay_want.txt" "$TMP/pay.txt" \
      | awk -F'|' '$2 != $3 { printf "        %-42s oracle=[%s] ours=[%s]\n", $1, $2, $3 }' \
      | head -12
    fail=1
  fi
fi

# --- 3. the gRPC message prefix -----------------------------------------
# Not part of HTTP/2, and not checkable against hyperframe. The oracle here is a
# MEASUREMENT: grpcurl 1.8.8 was observed sending `00 0000000f` ahead of a
# 15-byte message on a real connection. Pinned as a recorded fact, with its
# provenance, rather than derived from the same prose the implementation read.
{
  echo 'import "../contrib/http2/frame.mere";'
  echo 'let msg = bytes_of_hex "220d68656c6c6f2e47726565746572";'
  echo 'let _ = print (hex_of_bytes (H2.grpc_message msg));'
  echo 'let (c, body, nxt) = H2.read_grpc_message (H2.grpc_message msg) 0;'
  echo 'print (str_of_int c ++ " " ++ hex_of_bytes body ++ " " ++ str_of_int nxt)'
} > "$ROOT/examples/.http2_parity_tmp.mere"
if run_subject "grpc framing" "$ROOT/examples/.http2_parity_tmp.mere" "$TMP/grpc_out.txt"; then
  sed '$d' "$TMP/grpc_out.txt" > "$TMP/grpc.txt"
  cat > "$TMP/grpc_want.txt" <<'EOF'
000000000f220d68656c6c6f2e47726565746572
0 220d68656c6c6f2e47726565746572 20
EOF
  if diff -q "$TMP/grpc_want.txt" "$TMP/grpc.txt" >/dev/null; then
    echo "  ok    grpc framing  matches the prefix grpcurl 1.8.8 was measured sending"
  else
    echo "  FAIL  grpc framing"
    diff "$TMP/grpc_want.txt" "$TMP/grpc.txt" | sed 's/^/        /' | head -8
    fail=1
  fi
fi

# --- the preface ---------------------------------------------------------
{
  echo 'import "../contrib/http2/frame.mere";'
  echo 'let _ = print (hex_of_bytes (bytes_of_str H2.preface));'
  echo 'print (str_of_int (str_len H2.preface))'
} > "$ROOT/examples/.http2_parity_tmp.mere"
if run_subject "preface" "$ROOT/examples/.http2_parity_tmp.mere" "$TMP/pre_out.txt"; then
  sed '$d' "$TMP/pre_out.txt" > "$TMP/pre.txt"
  python3 - "$TMP" <<'PY'
import sys, pathlib
from h2.connection import H2Connection  # noqa: F401  (asserts h2 is present)
PREFACE = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
pathlib.Path(sys.argv[1], "pre_want.txt").write_text(
    PREFACE.hex() + "\n" + str(len(PREFACE)) + "\n")
PY
  if diff -q "$TMP/pre_want.txt" "$TMP/pre.txt" >/dev/null; then
    echo "  ok    preface  24 bytes, identical to the one grpcurl sends"
  else
    echo "  FAIL  preface"
    diff "$TMP/pre_want.txt" "$TMP/pre.txt" | sed 's/^/        /'
    fail=1
  fi
fi

[ "$fail" = 0 ] && echo "http2_parity: ok" || echo "http2_parity: FAILED"
[ "$fail" = 0 ]

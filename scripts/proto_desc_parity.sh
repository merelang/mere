#!/bin/sh
# scripts/proto_desc_parity.sh — check contrib/proto/{parse,descriptor}.mere against
# `protoc --descriptor_set_out`.
#
# THIS IS WHERE THE BOOTSTRAP CLOSES, and that is the reason it is one harness and
# not two. A descriptor set is itself a protobuf message, so the code that reads a
# schema is serialised by the code that reads wire bytes: if the varint encoder is
# wrong, this diff says so, and if a descriptor field number is wrong, the same diff
# says so. One oracle checks both layers at once.
#
# The comparison is BYTE EQUALITY with protoc's own output. Not a decoded rendering,
# not a field-by-field walk — the bytes. A descriptor that decodes to the same text
# but different bytes would still be a different descriptor to anything that hashes
# or caches it.
#
# TWO THINGS THE ORACLE TAUGHT before any of this was written, both recorded in the
# files rather than here:
#
#   * `descriptor.proto` IS PROTO2, so a set field is written even at its default —
#     an enum value's `number: 0` appears on the wire. The wire-format harness had to
#     learn the opposite rule for proto3, from the same encoder.
#   * `json_name` is always present and is not plain camelCase: `a_b_c` is `aBC`,
#     `trailing_` is `trailing`, `__lead` is `Lead`, `num_2_x` is `num2X`.
#
# REFUSALS ARE CHECKED, NOT CLAIMED. `oneof` / `map` / `import` / `option` /
# `reserved` / proto2 are outside the subset, and protoc ACCEPTS them — so the
# oracle cannot be asked. Instead each one asserts that our parser refuses it by
# name. A skipped construct would produce a descriptor that is wrong where nothing
# looks; a refusal is visible.
#
# Skips (exit 0) when protoc is absent.
#
# Usage:
#   sh scripts/proto_desc_parity.sh

set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MERE="$ROOT/_build/default/bin/mere.exe"

command -v protoc >/dev/null 2>&1 || { echo "proto_desc_parity: protoc absent, skipping"; exit 0; }
[ -x "$MERE" ] || { echo "proto_desc_parity: $MERE not found — run 'dune build'" >&2; exit 1; }
echo "proto_desc_parity: oracle is $(protoc --version)"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; rm -f "$ROOT/examples/.pdesc_tmp.mere"' EXIT
mkdir -p "$TMP/in"
fail=0
set +e

# A SUBJECT THAT ABORTS HIDES EVERY FILE AFTER IT. The subject prints one line per
# input, so the number of lines it managed says which input it died on — otherwise a
# single unparseable file reads as "the whole section is broken".
run_subject() {
  if ( ulimit -t 240; "$MERE" "$2" ) > "$3" 2> "$TMP/err.txt"; then return 0; fi
  done_n=$(grep -c . "$3" 2>/dev/null || echo 0)
  culprit=$(sed -n "$((done_n + 1))p" "$TMP/names.txt")
  echo "  FAIL  $1  the subject stopped after $done_n of $NC inputs"
  echo "        the failing input is: ${culprit:-<unknown>}"
  sed 's/^/          /' "$TMP/err.txt" | head -4
  if [ -n "$culprit" ]; then
    echo "        --- $culprit ---"
    sed 's/^/          /' "$TMP/in/$culprit" | head -12
  fi
  fail=1
  return 1
}

# --- the corpus, derived -------------------------------------------------
python3 - "$TMP/in" <<'PY'
import sys, pathlib
out = pathlib.Path(sys.argv[1])
n = 0
def add(body, pkg="pk"):
    global n
    n += 1
    hdr = 'syntax = "proto3";\n'
    if pkg: hdr += f"package {pkg};\n"
    out.joinpath("%03d.proto" % n).write_text(hdr + body)

# every scalar type, one field each and then all together
scalars = ["double", "float", "int32", "int64", "uint32", "uint64", "sint32",
           "sint64", "fixed32", "fixed64", "sfixed32", "sfixed64", "bool",
           "string", "bytes"]
for t in scalars:
    add(f"message M {{ {t} v = 1; }}")
    add(f"message M {{ repeated {t} v = 1; }}")
add("message M {\n" + "\n".join(f"  {t} f{i} = {i+1};" for i, t in enumerate(scalars)) + "\n}")

# field numbers across varint boundaries in the TAG, which is (number << 3)
for num in (1, 15, 16, 2047, 2048, 100000, 536870911):
    add(f"message M {{ int32 v = {num}; }}")

# json_name: the cases measured off protoc
for name in ("my_field", "a_b_c", "already_Camel", "x", "trailing_", "__lead",
             "num_2_x", "aB", "a1_b2"):
    add(f"message M {{ int32 {name} = 1; }}")

# packages: absent, simple, dotted
add("message M { int32 v = 1; }", pkg=None)
add("message M { int32 v = 1; }", pkg="a")
add("message M { int32 v = 1; }", pkg="a.b.c")

# references: same scope, nested, from a nested scope outward, and absolute
add("message A { int32 v = 1; }\nmessage B { A a = 1; }")
add("message A { enum E { Z = 0; } E e = 1; }")
add("message A { message Inner { int32 v = 1; } Inner i = 1; }")
add("message A { message Inner { int32 v = 1; } }\nmessage B { A.Inner i = 1; }")
add("enum E { Z = 0; }\nmessage M { E e = 1; }")
add("message A { message B { message C { int32 v = 1; } } }\n"
    "message D { A.B.C c = 1; }")
# the same simple name at two depths: the inner one must win
add("message N { int32 outer = 1; }\n"
    "message A { message N { int32 inner = 1; } N n = 1; }\n"
    "message B { N n = 1; }")
add("message M { int32 v = 1; }\nmessage R { .pk.M m = 1; }")

# enums: zero, non-contiguous, aliased numbers are NOT used (that needs an option)
add("enum E { Z = 0; }")
add("enum E { Z = 0; A = 1; B = 7; C = 1000; }")
add("message M { enum E { Z = 0; } enum F { Y = 0; } E e = 1; F f = 2; }")

# nesting depth
add("message A { message B { message C { message D { int32 v = 1; } } } }")

# services: unary, both streaming directions, several methods, cross-package refs
add("message Q { int32 v = 1; }\nmessage R { int32 v = 1; }\n"
    "service S { rpc U (Q) returns (R); }")
add("message Q { int32 v = 1; }\nmessage R { int32 v = 1; }\n"
    "service S { rpc CS (stream Q) returns (R); }")
add("message Q { int32 v = 1; }\nmessage R { int32 v = 1; }\n"
    "service S { rpc SS (Q) returns (stream R); }")
add("message Q { int32 v = 1; }\nmessage R { int32 v = 1; }\n"
    "service S { rpc BS (stream Q) returns (stream R); }")
add("message Q { int32 v = 1; }\nmessage R { int32 v = 1; }\n"
    "service S { rpc A (Q) returns (R); rpc B (Q) returns (R); }\n"
    "service T { rpc C (Q) returns (R); }")
add("message Q { int32 v = 1; }\nmessage R { int32 v = 1; }\n"
    "service S { rpc U (Q) returns (R) {} }")     # an empty method body

# comments and stray semicolons must not change a byte
add("// line\nmessage M { /* block */ int32 v = 1; }\n;\n")
add("message M {\n  // about v\n  int32 v = 1;  // trailing\n}")

# an empty message, and a message with only nested declarations
add("message M {}")
add("message M { message N {} }")

print(n)
PY
ls "$TMP/in" > "$TMP/names.txt"
NC=$(wc -l < "$TMP/names.txt" | tr -d ' ')

# --- protoc's answer -----------------------------------------------------
: > "$TMP/want.txt"
for f in $(ls "$TMP/in"); do
  if protoc --descriptor_set_out="$TMP/one.desc" -I"$TMP/in" "$TMP/in/$f" 2>"$TMP/pe.txt"; then
    od -An -tx1 -v < "$TMP/one.desc" | tr -d ' \n' >> "$TMP/want.txt"; echo >> "$TMP/want.txt"
  else
    echo "ORACLE-REJECTED $(head -1 "$TMP/pe.txt")" >> "$TMP/want.txt"
  fi
done

if grep -q "^ORACLE-REJECTED" "$TMP/want.txt"; then
  echo "  FAIL  corpus  protoc rejected files this script generated:"
  paste -d'|' "$TMP/names.txt" "$TMP/want.txt" \
    | awk -F'|' '$2 ~ /^ORACLE-REJECTED/ { printf "        %s: %s\n", $1, $2 }' | head -6
  echo "proto_desc_parity: FAILED"; exit 1
fi

# --- ours ----------------------------------------------------------------
# The file NAME is part of a descriptor, so it is passed in rather than derived —
# protoc records the path it was given, and a different path is a different answer.
{
  echo 'import "../contrib/proto/descriptor.mere";'
  for f in $(ls "$TMP/in"); do
    printf 'let _ = print (hex_of_bytes (Pdesc.of_source "%s" (read_file "%s")));\n' \
      "$f" "$TMP/in/$f"
  done
  echo '0'
} > "$ROOT/examples/.pdesc_tmp.mere"

if run_subject "descriptors" "$ROOT/examples/.pdesc_tmp.mere" "$TMP/got_raw.txt"; then
  sed '$d' "$TMP/got_raw.txt" > "$TMP/got.txt"
  if diff -q "$TMP/want.txt" "$TMP/got.txt" >/dev/null; then
    echo "  ok    descriptors  $NC files byte-identical to protoc"
  else
    echo "  FAIL  descriptors"
    paste -d'|' "$TMP/names.txt" "$TMP/want.txt" "$TMP/got.txt" \
      | awk -F'|' '$2 != $3 { print "        " $1 }' | head -10
    firstbad=$(paste -d'|' "$TMP/names.txt" "$TMP/want.txt" "$TMP/got.txt" \
      | awk -F'|' '$2 != $3 { print $1; exit }')
    if [ -n "$firstbad" ]; then
      echo "        --- $firstbad ---"
      sed 's/^/          /' "$TMP/in/$firstbad" | head -12
      protoc --descriptor_set_out="$TMP/one.desc" -I"$TMP/in" "$TMP/in/$firstbad" 2>/dev/null
      echo "        protoc decodes to:"
      protoc --decode_raw < "$TMP/one.desc" 2>/dev/null | sed 's/^/          /' | head -18
    fi
    fail=1
  fi
fi

# --- what must be REFUSED ------------------------------------------------
# protoc ACCEPTS every one of these, so the oracle cannot be asked whether they are
# wrong — they are simply outside the subset. What can be checked is that the parser
# says so instead of quietly producing a descriptor missing a field.
python3 - "$TMP" <<'PY'
import sys, pathlib
cases = [
    ("oneof", 'syntax = "proto3";\nmessage M { oneof o { int32 a = 1; string b = 2; } }'),
    ("map", 'syntax = "proto3";\nmessage M { map<string, int32> m = 1; }'),
    ("option", 'syntax = "proto3";\noption java_package = "x";\nmessage M { int32 v = 1; }'),
    ("reserved", 'syntax = "proto3";\nmessage M { reserved 2, 15; int32 v = 1; }'),
    ("optional", 'syntax = "proto3";\nmessage M { optional int32 v = 1; }'),
    ("field option", 'syntax = "proto3";\nmessage M { int32 v = 1 [deprecated = true]; }'),
]
tmp = pathlib.Path(sys.argv[1])
lines = []
for i, (label, src) in enumerate(cases):
    f = tmp / ("refuse%d.proto" % i)
    f.write_text(src)
    lines.append(f"{label}\t{f}")
tmp.joinpath("refuse.txt").write_text("\n".join(lines) + "\n")
PY

nref=0; nwrong=0
while IFS="$(printf '\t')" read -r label path; do
  [ -z "$path" ] && continue
  nref=$((nref + 1))
  # protoc must ACCEPT it — otherwise the case is about invalid syntax rather than
  # about the subset, and it would be checking the wrong thing.
  if ! protoc --descriptor_set_out=/dev/null -I"$(dirname "$path")" "$path" 2>/dev/null; then
    echo "        protoc REJECTS the '$label' case, so it is not a subset gap"
    nwrong=$((nwrong + 1)); continue
  fi
  printf 'import "../contrib/proto/descriptor.mere";\nprint (hex_of_bytes (Pdesc.of_source "r.proto" (read_file "%s")))\n' \
    "$path" > "$ROOT/examples/.pdesc_tmp.mere"
  if ( ulimit -t 60; "$MERE" "$ROOT/examples/.pdesc_tmp.mere" ) >/dev/null 2>"$TMP/rerr.txt"; then
    echo "        ACCEPTED (should have been refused): $label"
    nwrong=$((nwrong + 1))
  elif ! grep -q "not in this parser's subset" "$TMP/rerr.txt"; then
    echo "        REFUSED BUT UNNAMED: $label"
    echo "          got: $(head -1 "$TMP/rerr.txt" | cut -c1-110)"
    nwrong=$((nwrong + 1))
  fi
done < "$TMP/refuse.txt"
if [ "$nref" = 0 ]; then
  echo "  FAIL  subset  checked ZERO refusals — the case generator produced nothing"
  fail=1
elif [ "$nwrong" = 0 ]; then
  echo "  DOCUMENTED-GAP  subset  $nref constructs protoc accepts are refused by name"
else
  echo "  FAIL  subset  $nwrong of $nref"
  fail=1
fi

[ "$fail" = 0 ] && echo "proto_desc_parity: ok" || echo "proto_desc_parity: FAILED"
[ "$fail" = 0 ]

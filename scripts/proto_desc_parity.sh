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

# --- options -------------------------------------------------------------
# Every one of these is compared as BYTES against protoc, which is what makes the
# option feature checkable at all: an option is a field number in a submessage, and
# the numbers are descriptor.proto's rather than this schema's.
#
# THE ORDER IS THE INTERESTING PART. protoc emits options in ASCENDING FIELD NUMBER,
# not source order — so `go_package` (11) written first comes back after
# `java_package` (1). Each of the multi-option cases below is written in DESCENDING
# field order on purpose, so a writer that keeps source order produces different bytes.
add('option java_package = "com.example";\nmessage M { int32 v = 1; }')
add('option go_package = "example.com/pk";\nmessage M { int32 v = 1; }')
add('option go_package = "z";\noption java_package = "a";\nmessage M { int32 v = 1; }')
add('option java_outer_classname = "Outer";\noption java_multiple_files = true;\n'
    'message M { int32 v = 1; }')
add('option optimize_for = SPEED;\nmessage M { int32 v = 1; }')
add('option optimize_for = CODE_SIZE;\nmessage M { int32 v = 1; }')
add('option optimize_for = LITE_RUNTIME;\nmessage M { int32 v = 1; }')
add('option deprecated = true;\nmessage M { int32 v = 1; }')
add('option cc_enable_arenas = false;\nmessage M { int32 v = 1; }')
add('option ruby_package = "R";\noption php_namespace = "P";\noption swift_prefix = "S";\n'
    'option csharp_namespace = "C";\noption objc_class_prefix = "O";\n'
    'message M { int32 v = 1; }')

# Field options. `packed = false` on a repeated scalar is the one that changes what a
# DECODER must do, and `deprecated` is by far the most common in real schemas.
add("message M { int32 v = 1 [deprecated = true]; }")
add("message M { int32 v = 1 [deprecated = false]; }")
add("message M { repeated int32 v = 1 [packed = false]; }")
add("message M { repeated int32 v = 1 [packed = true]; }")
add("message M { int64 v = 1 [jstype = JS_STRING]; }")
add("message M { int64 v = 1 [jstype = JS_NORMAL]; }")
add("message M { int64 v = 1 [jstype = JS_NUMBER, deprecated = true]; }")
add("message M { bytes v = 1 [ctype = CORD]; }")

# `json_name` is NOT an option: it sets FieldDescriptorProto's own field 10 and
# produces no options submessage. Measured, and it is why the encoder pulls it out of
# the bracket list rather than looking it up in the option table.
add('message M { string my_field = 1 [json_name = "wire"]; }')
add('message M { string my_field = 1 [json_name = "wire", deprecated = true]; }')

# Options on every other declaration kind.
add("message M { option deprecated = true; int32 v = 1; }")
add("message M { option message_set_wire_format = false;\n"
    "  option no_standard_descriptor_accessor = false; int32 v = 1; }")
add("enum E { option allow_alias = true; A = 0; B = 0; }")
add("enum E { option deprecated = true; A = 0; }")
add("enum E { A = 0; B = 1 [deprecated = true]; }")
add("message Q { int32 v = 1; }\nservice S { option deprecated = true;\n"
    "  rpc U (Q) returns (Q); }")
add("message Q { int32 v = 1; }\nservice S {\n"
    "  rpc U (Q) returns (Q) { option deprecated = true; } }")
add("message Q { int32 v = 1; }\nservice S {\n"
    "  rpc U (Q) returns (Q) { option idempotency_level = NO_SIDE_EFFECTS; } }")
add("message Q { int32 v = 1; }\nservice S {\n"
    "  rpc U (Q) returns (Q) { option idempotency_level = IDEMPOTENT;\n"
    "                          option deprecated = true; } }")
# The empty body again, now that a body may hold options: `{}` still has to emit an
# EMPTY options submessage and `;` still has to emit nothing.
add("message Q { int32 v = 1; }\nservice S { rpc U (Q) returns (Q) {} }")
add("message Q { int32 v = 1; }\nservice S { rpc U (Q) returns (Q); }")

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

# --- imports, which need more than one file ------------------------------
#
# The single-file corpus above cannot express these: a cross-file type reference
# resolves to `.package.Type` using the IMPORTED file's package, and whether it is
# TYPE_MESSAGE or TYPE_ENUM comes from the imported file's declarations. So both sides
# get a directory.
#
# What each case is for:
#   * the three kinds of reference — qualified into another package, unqualified into
#     the SAME package in a different file, and an enum (a different type code)
#   * `public` and `weak`, whose indices go in separate lists from the paths
#   * an import that is declared and never used, which still appears in `dependency`
#   * the ORDER: `dependency` is field 3 and `message_type` is 4, so paths come before
#     messages, while `public_dependency` (10) and `weak_dependency` (11) come after
mkdir -p "$TMP/imp"
python3 - "$TMP/imp" <<'PY'
import sys, pathlib, json
d = pathlib.Path(sys.argv[1])
files = {
  "d1.proto": 'syntax = "proto3";\npackage dep;\nmessage Shared { string s = 1; }\nenum Kind { A = 0; B = 1; }\n',
  "d2.proto": 'syntax = "proto3";\npackage other;\nmessage Second { int32 t = 1; }\n',
  "same.proto": 'syntax = "proto3";\npackage pk;\nmessage Local { int32 l = 1; }\n',
  "nopkg.proto": 'syntax = "proto3";\nmessage Bare { int32 b = 1; }\n',
  "mid_pub.proto": 'syntax = "proto3";\npackage mid;\nimport public "d1.proto";\nmessage Mid { dep.Shared s = 1; }\n',
}
cases = {
  # target file -> its own source; every other file above is available to both sides.
  "t_qual.proto": 'syntax = "proto3";\npackage pk;\nimport "d1.proto";\nmessage M { dep.Shared a = 1; }\n',
  "t_enum.proto": 'syntax = "proto3";\npackage pk;\nimport "d1.proto";\nmessage M { dep.Kind k = 1; }\n',
  "t_samepkg.proto": 'syntax = "proto3";\npackage pk;\nimport "same.proto";\nmessage M { Local c = 1; }\n',
  "t_nopkg.proto": 'syntax = "proto3";\npackage pk;\nimport "nopkg.proto";\nmessage M { Bare b = 1; }\n',
  "t_two.proto": 'syntax = "proto3";\npackage pk;\nimport "d1.proto";\nimport "d2.proto";\n'
                 'message M { dep.Shared a = 1; other.Second b = 2; }\n',
  "t_public.proto": 'syntax = "proto3";\npackage pk;\nimport "d1.proto";\nimport public "d2.proto";\n'
                    'message M { dep.Shared a = 1; other.Second b = 2; }\n',
  "t_weak.proto": 'syntax = "proto3";\npackage pk;\nimport "d1.proto";\nimport weak "same.proto";\n'
                  'message M { dep.Shared a = 1; Local c = 2; }\n',
  "t_all3.proto": 'syntax = "proto3";\npackage pk;\nimport "d1.proto";\nimport public "d2.proto";\n'
                  'import weak "same.proto";\nmessage M { dep.Shared a = 1; other.Second b = 2; Local c = 3; }\n',
  "t_unused.proto": 'syntax = "proto3";\npackage pk;\nimport "d1.proto";\nmessage M { int32 v = 1; }\n',
  # `public` is transitive: the middle file re-exports d1, so this reaches dep.Shared
  # WITHOUT importing d1 itself. Measured: protoc accepts this and rejects the same
  # shape through a private import.
  "t_transitive.proto": 'syntax = "proto3";\npackage pk;\nimport "mid_pub.proto";\n'
                        'message M { dep.Shared a = 1; mid.Mid m = 2; }\n',
  "t_absolute.proto": 'syntax = "proto3";\npackage pk;\nimport "d1.proto";\nmessage M { .dep.Shared a = 1; }\n',
}
for n, src in files.items(): d.joinpath(n).write_text(src)
for n, src in cases.items(): d.joinpath(n).write_text(src)
d.joinpath("targets.txt").write_text("\n".join(sorted(cases)) + "\n")
d.joinpath("deps.txt").write_text("\n".join(sorted(files)) + "\n")
PY
NIMP=$(grep -c . "$TMP/imp/targets.txt")

# protoc's answer per target.
ibad=0
: > "$TMP/imp/want.txt"
while IFS= read -r t; do
  [ -z "$t" ] && continue
  if ! protoc --descriptor_set_out="$TMP/imp/$t.pb" -I"$TMP/imp" "$TMP/imp/$t" 2>"$TMP/imp/perr.txt"; then
    echo "        protoc REJECTS the harness's own case $t:"
    sed 's/^/          /' "$TMP/imp/perr.txt" | head -2
    ibad=$((ibad + 1)); continue
  fi
  python3 -c "import sys;print(open(sys.argv[1],'rb').read().hex())" "$TMP/imp/$t.pb" >> "$TMP/imp/want.txt"
done < "$TMP/imp/targets.txt"

# Our answer. Every dep file is offered for every target: an import the target does not
# declare must not become visible just because it was supplied, which is what makes
# `t_unused` and the transitive case mean anything.
{
  echo 'import "../contrib/proto/descriptor.mere";'
  echo 'let rec arg_at = fn (xs, k: int, d: str) ->'
  echo '  match xs with [] -> d | [h, ...t] -> if k == 0 then h else arg_at t (k - 1) d;'
  echo 'let dir = arg_at (args ()) 0 "";'
  echo 'let load = fn (n: str) -> (n, read_file (dir ++ "/" ++ n));'
  printf 'let deps = list_map ['
  first=1
  while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    [ "$first" = 1 ] || printf ', '
    printf '"%s"' "$dep"; first=0
  done < "$TMP/imp/deps.txt"
  printf '] load;\n'
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    printf 'let _ = print (hex_of_bytes (Pdesc.of_sources "%s" (read_file (dir ++ "/%s")) deps));\n' "$t" "$t"
  done < "$TMP/imp/targets.txt"
  echo '0'
} > "$ROOT/examples/.pdesc_tmp.mere"

if ( ulimit -t 300; "$MERE" "$ROOT/examples/.pdesc_tmp.mere" "$TMP/imp" ) \
     > "$TMP/imp/raw.txt" 2>"$TMP/imp/err.txt"; then
  sed '$d' "$TMP/imp/raw.txt" > "$TMP/imp/ours.txt"
  if [ "$ibad" != 0 ]; then
    echo "  FAIL  imports  $ibad of the harness's own cases were rejected by protoc"
    fail=1
  elif diff -q "$TMP/imp/want.txt" "$TMP/imp/ours.txt" >/dev/null; then
    echo "  ok    imports  $NIMP multi-file cases byte-identical to protoc"
  else
    echo "  FAIL  imports"
    paste -d'|' "$TMP/imp/targets.txt" "$TMP/imp/want.txt" "$TMP/imp/ours.txt" \
      | awk -F'|' '$2 != $3 { printf "        %-22s\n          protoc=%.90s\n          ours  =%.90s\n", $1, $2, $3 }' \
      | head -12
    fail=1
  fi
else
  echo "  FAIL  imports  the subject failed:"
  sed 's/^/        /' "$TMP/imp/err.txt" | head -4
  fail=1
fi

# --- the visibility rule, in BOTH directions ----------------------------
#
# A private import is NOT transitive and a public one is. Measured on protoc:
#   "cc.Deep" seems to be defined in "c.proto", which is not imported by "a.proto"
# A resolver that followed every import transitively would accept a schema protoc
# rejects — the wrong direction to be wrong in. So the refusal is checked, not assumed.
python3 - "$TMP/imp" <<'PY'
import sys, pathlib
d = pathlib.Path(sys.argv[1])
d.joinpath("mid_priv.proto").write_text(
  'syntax = "proto3";\npackage mid2;\nimport "d1.proto";\nmessage MidP { dep.Shared s = 1; }\n')
d.joinpath("t_priv_trans.proto").write_text(
  'syntax = "proto3";\npackage pk;\nimport "mid_priv.proto";\nmessage M { dep.Shared a = 1; }\n')
PY
if protoc --descriptor_set_out=/dev/null -I"$TMP/imp" "$TMP/imp/t_priv_trans.proto" 2>/dev/null; then
  echo "  FAIL  visibility  protoc ACCEPTED a private transitive reference — the rule this"
  echo "        section is built on does not hold, so the refusal below means nothing"
  fail=1
else
  printf 'import "../contrib/proto/descriptor.mere";\nlet load = fn (n: str) -> (n, read_file ("%s/" ++ n));\nprint (hex_of_bytes (Pdesc.of_sources "t_priv_trans.proto" (read_file "%s/t_priv_trans.proto") [load "mid_priv.proto", load "d1.proto"]))\n' \
    "$TMP/imp" "$TMP/imp" > "$ROOT/examples/.pdesc_tmp.mere"
  if ( ulimit -t 60; "$MERE" "$ROOT/examples/.pdesc_tmp.mere" ) >/dev/null 2>"$TMP/imp/verr.txt"; then
    echo "  FAIL  visibility  we ACCEPTED a private transitive reference protoc rejects"
    fail=1
  elif ! grep -q "no such type" "$TMP/imp/verr.txt"; then
    echo "  FAIL  visibility  refused, but not as an unresolved type:"
    echo "        got: $(head -1 "$TMP/imp/verr.txt" | cut -c1-110)"
    fail=1
  else
    echo "  ok    visibility  a private import is not transitive; a public one is"
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
    ("reserved", 'syntax = "proto3";\nmessage M { reserved 2, 15; int32 v = 1; }'),
    ("optional", 'syntax = "proto3";\nmessage M { optional int32 v = 1; }'),
    # `option`, `field option` and `import` USED TO BE HERE. They are implemented now, and this
    # list is what said so: both assertions failed and named themselves stale on the
    # first run after the encoder landed.
    #
    # WHAT IS LEFT OF THE OPTION FEATURE is the options protoc accepts and this encoder
    # does not carry. The label is the OPTION NAME, which is what the encoder's refusal
    # quotes — so these are checked exactly like the constructs above, and adding one to
    # the table makes its case fail as stale.
    #
    # An unknown option name cannot be tested this way at all: protoc REJECTS
    # `option no_such_thing = 1`, so there is no protoc-accepted file that reaches that
    # branch. Neither can a wrong-typed value (`option java_package = true`), which
    # protoc also rejects. Both guards are defensive and say so in the code.
    ("java_string_check_utf8",
     'syntax = "proto3";\noption java_string_check_utf8 = true;\nmessage M { int32 v = 1; }'),
    ("php_class_prefix",
     'syntax = "proto3";\noption php_class_prefix = "P";\nmessage M { int32 v = 1; }'),
    ("cc_generic_services",
     'syntax = "proto3";\noption cc_generic_services = true;\nmessage M { int32 v = 1; }'),
    ("weak", 'syntax = "proto3";\nmessage M { int32 v = 1 [weak = false]; }'),
    ("debug_redact", 'syntax = "proto3";\nmessage M { int32 v = 1 [debug_redact = true]; }'),
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
  elif ! grep -qE "not in this (parser|encoder)'s subset" "$TMP/rerr.txt"; then
    echo "        REFUSED BUT UNNAMED: $label"
    echo "          got: $(head -1 "$TMP/rerr.txt" | cut -c1-110)"
    nwrong=$((nwrong + 1))
  # THE MESSAGE MUST NAME THE CONSTRUCT BEING TESTED. Checking only for "not in this
  # parser's subset" let a file refused for an UNRELATED reason count as a pass: a
  # custom-option case needed `import` to be valid protoc, so it was refused at the
  # import and the harness credited it to custom options. A case that cannot fail for
  # its own reason is not testing its own reason.
  elif ! grep -q "'$label'" "$TMP/rerr.txt"; then
    echo "        REFUSED FOR THE WRONG REASON: $label"
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

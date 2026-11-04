#!/usr/bin/env python3
"""Formatting reads containers, including empty storage and nested values."""
import argparse
from pathlib import Path
import subprocess
import tempfile

from rv_builder_owner_check import checked, run_suite
from rv_vec_owner_check import MERE, CC, execute


OWNED = ("{op}: an OwnedVec belongs to one thread -- the one that made it, or the one spawn moved it into -- "
         "and another used it; move it into the thread by capturing it in the closure spawn is given")


def fixtures():
    specs = {
        "vec": ("vec_new ()", "vec_push v 1", "vec_push v 9", "vec_len v", "int Vec", "Vec", "vec_push", True,
                ("Vec[]", "Vec[1]"), ("[]", "[1]")),
        "map": ("map_new ()", 'map_set v "k" 1', 'map_set v "x" 9', "map_len v", "Map[__heap, str, int]", "Map", "map_set", True,
                ("Map[]", 'Map["k" => 1]'), ("{}", '{"k":1}')),
        "strbuf": ("strbuf_new ()", 'strbuf_push v "a"', 'strbuf_push v "b"', "strbuf_len v", "StrBuf[__heap]", "StrBuf", "strbuf_push", True,
                   ('StrBuf[""]', 'StrBuf["a"]'), ('""', '"a"')),
        "bytebuf": ("bytebuf_new 0", "bytebuf_push v 1", "bytebuf_push v 9", "bytebuf_len v", "ByteBuf[__heap]", "ByteBuf", "bytebuf_push", True,
                    ("bytebuf[]", "bytebuf[01]"), ('""', '"01"')),
        "listbuf": ("lb_new ()", "lb_push v 1", "lb_push v 9", "list_len (lb_to_list v)", "ListBuf[__heap, int]", "ListBuf", "lb_push", False,
                    ("ListBuf[]", "ListBuf[1]"), ("[]", "[1]")),
        "owned_new": ("owned_vec_new ()", "owned_vec_push v 1", "owned_vec_push v 9", "owned_vec_len v", "int OwnedVec", "OwnedVec", "owned_vec_push", False,
                      ("Vec[]", "Vec[1]"), ("[]", "[1]")),
        "owned_copy": ("let a = vec_new () in let _ = (if false then vec_push a 0 else ()) in vec_to_owned a",
                       "owned_vec_push v 1", "owned_vec_push v 9", "owned_vec_len v", "int OwnedVec", "OwnedVec", "owned_vec_push", False,
                       ("Vec[]", "Vec[1]"), ("[]", "[1]")),
    }
    cases = {}
    for kind, spec in specs.items():
        make, seed, write, size, ty, label, write_op, shared, shown, json = spec
        for full in (False, True):
            state = "full" if full else "empty"
            setup = f"""let launch = fn (f: unit -> unit) -> spawn f;
let mk = fn () -> let v = {make} in let _ = (if false then {seed} else ()) in let _ = {seed if full else '()'} in v;
let v = mk ();
let results = channel_new ();
"""
            for op, display in (("show", shown[full]), ("to_json", json[full])):
                native = kind == "vec" or (label == "OwnedVec" and op == "show")
                wrappers = {
                    "plain": ("", "v"),
                    "tuple": ("", "(v, 7)"),
                    "record": (f"type Box = {{ item: {ty} }};\n", "Box { item = v }"),
                    "variant": (f"type Box = Wrap of {ty};\n", "Wrap v"),
                    "list": ("", "[v]"),
                    "option": ("", "Some v"),
                }
                for wrapper, (decl, view) in wrappers.items():
                    name = f"{kind}_{state}_{op}_{wrapper}"
                    if shared:
                        read_result = "read-ok"
                        write_result = (f"{write_op}: a {label} another thread has read was written -- once a second thread reads a {label} "
                                        f"it is shared, and a shared {label} is read-only; give it one owner thread and send it messages over a Channel")
                    else:
                        read_result = (OWNED.format(op=op) if label == "OwnedVec" else
                                       f"{op}: a ListBuf made by one thread was written by another -- a ListBuf is not safe to share between threads; give it one owner thread and send it messages over a Channel")
                        write_result = "allowed"
                    source = decl + setup + f"""let h = launch (fn () -> channel_send results (try_or_msg (fn () -> let _ = {op} ({view}) in "read-ok") (fn msg -> msg)));
let _ = join h;
let _ = print (channel_recv results);
let _ = print (try_or_msg (fn () -> let _ = {write} in "allowed") (fn msg -> msg));
print_int ({size})
"""
                    expected = f"{read_result}\n{write_result}\n{int(full) + int(not shared)}\n".encode()
                    marker = ('__lang_ov_use(&v->owner, "show"); /* owned-show-owner */' if label == "OwnedVec" else
                              f"__LANG_READ(v); /* vec-{'show' if op == 'show' else 'json'}-read */")
                    cases["foreign_" + name] = (source, expected, native, kind == "vec", marker)
                    if kind == "strbuf" and wrapper == "plain":
                        # A saved partial application must observe sharing
                        # that happened after it captured the source buffer.
                        partial = source.replace('let h = launch', 'let push = strbuf_push v;\nlet h = launch')
                        partial = partial.replace('let _ = strbuf_push v "b" in "allowed"', 'let _ = push "b" in "allowed"')
                        cases["partial_" + name] = (partial, expected, False, False, None)
                    if label == "OwnedVec":
                        source = decl + setup + f"""let parent = fn () -> {write};
let h = spawn (fn () -> channel_send results (try_or_msg (fn () -> let _ = {op} ({view}) in "claimed") (fn msg -> msg)));
let _ = join h;
let _ = print (channel_recv results);
print (try_or_msg (fn () -> let _ = parent () in "allowed") (fn msg -> msg))
"""
                        cases["claim_" + name] = (source, ("claimed\n" + OWNED.format(op=write_op) + "\n").encode(), native, False, marker)
                # Formatting in the owner must preserve contents and leave the
                # source writable. Reading the immutable result elsewhere must
                # not mark the source, either.
                source = setup + f"""let snapshot = {op} v;
let _ = print snapshot;
let h = spawn (fn () -> channel_send results snapshot);
let _ = join h;
let _ = print (channel_recv results);
let _ = {write};
print_int ({size})
"""
                cases[f"owner_{kind}_{state}_{op}"] = (source, f"{display}\n{display}\n{int(full) + 1}\n".encode(), native, kind == "vec", None)
    for route in ("vec_vec", "map_vec", "vec_map"):
        inner_map = route == "vec_map"
        outer_map = route == "map_vec"
        make = "map_new ()" if inner_map else "vec_new ()"
        seed = 'map_set v "k" 1' if inner_map else "vec_push v 1"
        write = 'map_set v "x" 9' if inner_map else "vec_push v 9"
        size = "map_len v" if inner_map else "vec_len v"
        outer = ('let w = map_new (); let _ = map_set w "item" v;' if outer_map else
                 'let w = vec_new (); let _ = vec_push w v;')
        outer_write = 'map_set w "other" v' if outer_map else "vec_push w v"
        outer_size = "map_len w" if outer_map else "vec_len w"
        for full in (False, True):
            for op in ("show", "to_json"):
                source = f"""let launch = fn (f: unit -> unit) -> spawn f;
let mk = fn () -> let v = {make} in let _ = (if false then {seed} else ()) in let _ = {seed if full else '()'} in v;
let v = mk ();
{outer}
let h = launch (fn () -> let _ = {op} w in ());
let _ = join h;
let _ = print (try_or (fn () -> let _ = {write} in "allowed") "inner-shared");
let _ = print (try_or (fn () -> let _ = {outer_write} in "allowed") "outer-shared");
let _ = print_int ({size});
print_int ({outer_size})
"""
                native = route == "vec_vec"
                name = f"nested_{route}_{'full' if full else 'empty'}_{op}"
                cases[name] = (source, f"inner-shared\nouter-shared\n{int(full)}\n1\n".encode(), native, native, None)
    # Showing a finalized builder is a read, and must not undo finalization.
    for full in (False, True):
        for op in ("show", "to_json"):
            source = f"""let v = lb_new ();
let _ = (if {str(full).lower()} then lb_push v 1 else ());
let _ = lb_to_list v;
let _ = {op} v;
print (try_or (fn () -> let _ = lb_push v 9 in "allowed") "still-frozen")
"""
            cases[f"frozen_listbuf_{full}_{op}"] = (source, b"still-frozen\n", False, False, None)
    assert len(cases) == 264
    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--poison", action="store_true")
    parser.add_argument("--rv-only", action="store_true")
    args = parser.parse_args()
    cases = fixtures()
    if args.rv_only:
        selected = {name: case[0] for name, case in cases.items() if case[3]}
        assert len(selected) == 32
        poisons = [(f"foreign_vec_{state}_{op}_plain", ["__vec_read"])
                   for state in ("empty", "full") for op in ("show", "to_json")]
        run_suite("format_vec_owner", selected, poisons,
                  'let v = vec_new (); let _ = vec_push v 1; let _ = print (show v); print (to_json v)\n',
                  ["__vec_read", "__vec_track"], args.poison)
        return
    checks = 0
    with tempfile.TemporaryDirectory(prefix="container-format-owner-") as directory:
        tmp = Path(directory)

        def run_c(code):
            (tmp / "case.c").write_bytes(code)
            checked([CC, "-O2", "-w", "case.c", "-o", "case", "-lm", "-lpthread"], tmp)
            result = execute([tmp / "case"], tmp)
            return result.returncode, result.stdout, result.stderr

        for name, (source, expected, native, _, marker) in cases.items():
            file = tmp / "case.mere"
            file.write_text(source)
            result = execute([MERE, file], tmp)
            if (result.returncode, result.stdout, result.stderr) != (0, expected, b""):
                raise RuntimeError(f"{name}: interpreter: {result.returncode}, {result.stdout!r}, {result.stderr!r}; expected {expected!r}")
            checks += 1
            if native:
                code = checked([MERE, "-c", file], tmp)
                if run_c(code) != (0, expected, b""):
                    raise RuntimeError(f"{name}: C differs from the ownership contract")
                checks += 1
                if args.poison and name.startswith("foreign_") and name.endswith("_plain"):
                    mark = marker.encode()
                    if not code.count(mark):
                        raise RuntimeError(f"POISON {name}: missing formatting guard")
                    actual = run_c(code.replace(mark, b""))
                    if actual[0] or actual[2] or not actual[1].startswith(b"read-ok\nallowed\n") or actual[1] == expected:
                        raise RuntimeError(f"POISON {name}: removing its guard did not allow access: {actual!r}")
                    checks += 1
                    print(f"  ok    POISON C {name}", flush=True)
            print(f"  ok    {name}: interpreter" + (" and C" if native else ""), flush=True)
    expected_checks = 356 if args.poison else 348
    assert checks == expected_checks, (checks, expected_checks)
    print(f"container_format_owner: ok ({len(cases)} fixtures; {checks} checks)")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.TimeoutExpired, AssertionError, KeyError) as error:
        raise SystemExit(f"container_format_owner: FAIL {error}")

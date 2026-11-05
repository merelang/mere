#!/usr/bin/env python3
"""Map readers share explicit expectations across interpreter and compiled backends."""
import argparse
from dataclasses import dataclass
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

from rv_builder_owner_check import checked, run_suite
from rv_vec_owner_check import CC, MERE, ROOT, execute


ALL = ("interpreter", "C", "LLVM", "Wasm")
PREFIX = "let launch = fn (f: unit -> unit) -> spawn f;\n"
# Scalar/compound hash keys and the payload-variant linear fallback on LLVM.
KEYS = {
    "int": ("", "1", "2", "3"),
    "bool": ("", "true", "false", "false"),
    "str": ("", '"a"', '"b"', '"missing"'),
    "tuple": ("", '(1, "a")', '(2, "b")', '(3, "missing")'),
    "record": ('type Key = { id: int, name: str };\n',
               'Key { id = 1, name = "a" }', 'Key { id = 2, name = "b" }', 'Key { id = 3, name = "missing" }'),
    "enum": ("type Key = A | B | C;\n", "A", "B", "C"),
    "variant": ("type Key = A of int | B of int;\n", "A 1", "B 2", "A 3"),
}
STATES = {
    "empty": ("()", "", 0, -1),
    "full": ("let _ = map_set m k1 10 in map_set m k2 20", "10,20,", 2, 10),
    "erased": ("let _ = map_set m k1 10 in map_delete m k1", "", 0, -1),
    "mixed": ("let _ = map_set m k1 10 in let _ = map_set m k2 20 in map_delete m k1", "20,", 1, -1),
    "reinserted": ("let _ = map_set m k1 10 in let _ = map_set m k2 20 in let _ = map_delete m k1 in map_set m k1 30", "20,30,", 2, 30),
}
ITER = ('let b = strbuf_new () in '
        'let _ = map_iter m (fn k -> fn v -> strbuf_push b (str_of_int v ++ ",")) in strbuf_to_str b')


@dataclass
class Case:
    source: str
    expected: bytes
    backends: tuple = ALL
    rv: bool = True
    control: str = ""


def setup(kind, state):
    decl, key1, key2, absent = KEYS[kind]
    initial = STATES[state][0]
    return decl + PREFIX + f"""let k1 = {key1};
let k2 = {key2};
let missing = {absent};
let mk = fn () -> let m = map_new () in let _ = (if false then map_set m k1 0 else ()) in let _ = {initial} in m;
let m = mk ();
let results = channel_new ();
"""


def foreign_case(kind, state, expr, result, control=""):
    _, _, length, first = STATES[state]
    source = setup(kind, state) + f"""let h = launch (fn () -> channel_send results ({expr}));
let _ = join h;
let _ = print (channel_recv results);
let _ = print (try_or (fn () -> let _ = map_set m k1 90 in "allowed") "shared");
let _ = print_int (map_len m);
print_int (if map_has m k1 then map_get m k1 else (-1))
"""
    return Case(source, f"{result}\nshared\n{length}\n{first}\n".encode(), control=control)


def fixtures():
    cases = {}
    for kind in KEYS:
        for state in ("empty", "full", "erased"):
            control = "iter" if kind in {"int", "variant"} else ""
            cases[f"iter_{kind}_{state}"] = foreign_case(kind, state, ITER, STATES[state][1], control)
            # A bool has only two values: remove k2 first so the missing-key
            # checks really miss, even when this fixture starts with two keys.
            for op, expr, result in (
                ("get_missing", 'str_of_int (try_or (fn () -> map_get m missing) (-1))', "-1"),
                ("has_missing", 'if map_has m missing then "present" else "absent"', "absent"),
            ):
                case = foreign_case(kind, state, expr, result)
                if kind == "bool" and state == "full":
                    case.source = case.source.replace("let h = launch", "let _ = map_delete m k2;\nlet h = launch")
                    case.expected = f"{result}\nshared\n1\n10\n".encode()
                if kind == "variant" and state == "empty" and op == "get_missing":
                    case.control = "linear-get-fail"
                cases[f"{op}_{kind}_{state}"] = case
        # Owner reads, including failures, leave the Map writable. Reading a
        # snapshot made by map_iter in another thread only reads the snapshot.
        source = setup(kind, "full") + f"""let snapshot = {ITER};
let h = launch (fn () -> channel_send results snapshot);
let _ = join h;
let _ = print (channel_recv results);
let _ = map_set m k1 33;
let _ = print_int (map_get m k1);
print_int (map_len m)
"""
        cases[f"snapshot_{kind}"] = Case(source, b"10,20,\n33\n2\n")
    for kind in ("int", "variant"):
        for state, (_, values, length, first) in STATES.items():
            for op, expr, result in (
                ("len", "str_of_int (map_len m)", str(length)),
                ("generic_len", "str_of_int (len m)", str(length)),
                ("get", "str_of_int (try_or (fn () -> map_get m k1) (-1))", str(first)),
                ("has", 'if map_has m k1 then "present" else "absent"', "present" if first >= 0 else "absent"),
            ):
                cases[f"{op}_{kind}_{state}"] = foreign_case(kind, state, expr, result)
            if state in {"mixed", "reinserted"}:
                cases[f"iter_{kind}_{state}"] = foreign_case(kind, state, ITER, values)
        cases[f"metadata_{kind}"] = Case(setup(kind, "empty") + """let h = launch (fn () -> let _ = map_bytes m in ());
let _ = join h;
let _ = map_set m k1 90;
print_int (map_get m k1)
""", b"90\n")
        for op, partial, apply, expected in (
            ("get", "map_get m", "str_of_int (partial k1)", "33"),
            ("has", "map_has m", 'if partial k1 then "present" else "absent"', "present"),
            ("iter", "map_iter m", 'let b = strbuf_new () in let _ = partial (fn k -> fn v -> strbuf_push b (str_of_int v ++ ",")) in strbuf_to_str b', "33,"),
        ):
            source = setup(kind, "empty") + f"""let ready = channel_new ();
let go = channel_new ();
let h = launch (fn () ->
  let partial = {partial} in
  let _ = channel_send ready 0 in
  let _ = channel_recv go in channel_send results ({apply}));
let _ = channel_recv ready;
let _ = print (try_or (fn () -> let _ = map_set m k1 33 in "owner-ok") "early-read");
let _ = channel_send go 0;
let _ = join h;
let _ = print (channel_recv results);
print (try_or (fn () -> let _ = map_set m k1 90 in "allowed") "shared")
"""
            answer = f"owner-ok\n{expected}\nshared\n".encode()
            cases[f"partial_{kind}_{op}"] = Case(source, answer, ("interpreter",), False)
            wrapped = source.replace(f"let partial = {partial} in", f"let partial = fn a -> {partial} a in")
            cases[f"wrapper_{kind}_{op}"] = Case(wrapped, answer)
        for stage, callback, visits in (
            ("key", 'fn k -> let _ = vec_push visits 1 in fail "key callback"', 1),
            ("value", 'fn k -> fn v -> let _ = vec_push visits v in fail "value callback"', 1),
            ("slow_value", 'fn k -> let _ = vec_push visits 1 in fn v -> let _ = vec_push visits v in fail "value callback"', 2),
        ):
            expr = (f'let visits = vec_new () in let result = try_or (fn () -> let _ = map_iter m ({callback}) in "unexpected") "callback-failed" in '
                    'result ++ ":" ++ str_of_int (vec_len visits)')
            control = "callback-key" if stage == "key" else "callback-value"
            cases[f"callback_{kind}_{stage}"] = foreign_case(kind, "full", expr, f"callback-failed:{visits}", control)
        for slow in (False, True):
            callback = ('fn k -> let _ = strbuf_push trace "k;" in fn v -> strbuf_push trace (str_of_int v ++ ";")' if slow else
                        'fn k -> fn v -> strbuf_push trace (str_of_int v ++ ";")')
            source = setup(kind, "full") + f"""let trace = strbuf_new ();
let get_map = fn () -> let _ = strbuf_push trace "map;" in m;
let get_callback = fn () -> let _ = strbuf_push trace "fn;" in {callback};
let _ = map_iter (get_map ()) (get_callback ());
let _ = print (strbuf_to_str trace);
let _ = map_set m k1 33;
print_int (map_get m k1)
"""
            trace = "map;fn;k;10;k;20;" if slow else "map;fn;10;20;"
            cases[f"evaluation_{kind}_{'slow' if slow else 'fast'}"] = Case(source, f"{trace}\n33\n".encode())
        # The callback factory runs before operation entry. It may coordinate
        # with the owner, which can still update before the actual read starts.
        source = setup(kind, "empty") + """let ready = channel_new ();
let go = channel_new ();
let h = launch (fn () ->
  let b = strbuf_new () in
  let make = fn () -> let _ = channel_send ready 0 in let _ = channel_recv go in fn k -> fn v -> strbuf_push b (str_of_int v ++ ",") in
  let _ = map_iter m (make ()) in channel_send results (strbuf_to_str b));
let _ = channel_recv ready;
let _ = print (try_or (fn () -> let _ = map_set m k1 33 in "owner-ok") "early-read");
let _ = channel_send go 0;
let _ = join h;
let _ = print (channel_recv results);
print (try_or (fn () -> let _ = map_set m k1 90 in "allowed") "shared")
"""
        cases[f"factory_{kind}"] = Case(source, b"owner-ok\n33,\nshared\n")
        for state in ("empty", "full"):
            expr = 'str_of_int (region R loop x { match x with | None -> Continue m | Some copy -> Done (map_len copy) })'
            cases[f"carry_{kind}_{state}"] = foreign_case(kind, state, expr, str(STATES[state][2]), "map-carry")
    # A Map carry recursively copies its values on C. Reads of nested Maps
    # and Vecs must freeze those sources as well as the outer Map.
    for kind in ("map", "vec"):
        make = "map_new ()" if kind == "map" else "vec_new ()"
        seed = "map_set inner 1 10" if kind == "map" else "vec_push inner 10"
        read = "map_len (map_get copy 1)" if kind == "map" else "vec_len (map_get copy 1)"
        write = "map_set inner 1 90" if kind == "map" else "vec_push inner 90"
        source = PREFIX + f"""let inner = {make};
let _ = {seed};
let m = map_new ();
let _ = map_set m 1 inner;
let results = channel_new ();
let h = launch (fn () -> channel_send results (region R loop x {{ match x with | None -> Continue m | Some copy -> Done ({read}) }}));
let _ = join h;
let _ = print_int (channel_recv results);
let _ = print (try_or (fn () -> let _ = map_set m 1 inner in "allowed") "shared");
print (try_or (fn () -> let _ = {write} in "allowed") "shared")
"""
        cases[f"carry_nested_{kind}"] = Case(source, b"1\nshared\nshared\n", control=f"{kind}-carry")
    for nested in (False, True):
        if nested:
            make = "let v = vec_new () in let _ = vec_push v 10 in v"
            seed = "map_set m 1 original"
            change = "let v = map_get copy 1 in let _ = vec_set v 0 44 in vec_get v 0"
            original = "vec_get original 0"
            write = "vec_push original 90"
        else:
            make = "10"
            seed = "map_set m 1 original"
            change = "let _ = map_set copy 1 44 in map_get copy 1"
            original = "map_get m 1"
            write = "map_set m 1 90"
        source = PREFIX + f"""let original = {make};
let m = map_new ();
let _ = {seed};
let results = channel_new ();
let h = launch (fn () -> channel_send results (region R loop x {{ match x with | None -> Continue m | Some copy -> Done ({change}) }}));
let _ = join h;
let _ = print_int (channel_recv results);
let _ = print_int ({original});
print (try_or (fn () -> let _ = {write} in "allowed") "shared")
"""
        cases[f"carry_copy_{'nested_vec' if nested else 'map'}"] = Case(source, b"44\n10\nshared\n", ("C",), False)
    for state in ("empty", "full"):
        for op, expected in (("show", "Map[]" if state == "empty" else "Map[1 => 10, 2 => 20]"),
                             ("to_json", "{}" if state == "empty" else '{"1":10,"2":20}')):
            case = foreign_case("int", state, f"{op} m", expected)
            case.backends = ("interpreter",)
            case.rv = False
            cases[f"format_{state}_{op}"] = case
    return cases


def outcome(result):
    return result.returncode, result.stdout, result.stderr


def poison_exposes(actual, expected):
    return actual[0] == 0 and not actual[2] and b"allowed\n" in actual[1] and actual != expected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rv-only", action="store_true")
    parser.add_argument("--poison", action="store_true")
    args = parser.parse_args()
    cases = fixtures()
    # Keep the catalogue and backend denominator explicit, including cases
    # whose direct partial form is only supported by the interpreter.
    assert len(cases) == 152, "fixture catalogue changed"
    assert sum(len(c.backends) for c in cases.values()) == 572, "backend coverage changed"
    assert sum(c.rv for c in cases.values()) == 140, "RISC-V coverage changed"
    if args.rv_only:
        selected = {name: c.source for name, c in cases.items() if c.rv}
        expected = {name: c.expected for name, c in cases.items() if c.rv}
        poisons = [(name, ["__map_read", "__map_read_meta"]) for name in
                   ("iter_int_empty", "iter_variant_erased", "get_missing_int_full")]
        run_suite("map_read", selected, poisons,
                  'let m = map_new (); let _ = map_set m 1 10; map_iter m (fn k -> fn v -> print_int v)\n',
                  ["__map_read", "__map_track", "__map_write_"], args.poison,
                  expected_outputs=expected)
        return
    for tool in (CC, "clang", "wat2wasm", "node"):
        if not shutil.which(tool):
            raise RuntimeError(f"required tool missing: {tool}")
    checks = 0
    controls = 0
    with tempfile.TemporaryDirectory(prefix="map-read-") as directory:
        tmp = Path(directory)
        def native(code, backend):
            suffix = "c" if backend == "C" else "ll"
            (tmp / f"case.{suffix}").write_bytes(code)
            checked([CC if backend == "C" else "clang", "-O2", "-w", f"case.{suffix}", "-o", "case", "-lm", "-lpthread"], tmp)
            return outcome(execute([tmp / "case"], tmp))
        def wasm(code):
            (tmp / "module.wat").write_bytes(code)
            checked(["wat2wasm", "--enable-tail-call", "--enable-threads", "module.wat", "-o", "module.wasm"], tmp)
            return outcome(execute(["node", ROOT / "scripts/run_wasm.js", tmp / "module.wasm"], tmp))
        for name, case in cases.items():
            file = tmp / "case.mere"
            file.write_text(case.source)
            expected = (0, case.expected, b"")
            for backend in case.backends:
                if backend == "interpreter":
                    actual = outcome(execute([MERE, file], tmp))
                else:
                    flag = {"C": "-c", "LLVM": "-ll", "Wasm": "-w"}[backend]
                    code = checked([MERE, flag, file], tmp)
                    actual = wasm(code) if backend == "Wasm" else native(code, backend)
                if actual != expected:
                    raise RuntimeError(f"{name}: {backend}: {actual!r}; expected {expected!r}")
                checks += 1
                if not args.poison or not case.control or backend == "interpreter":
                    continue
                if case.control == "iter":
                    if backend == "C":
                        marker = b"__LANG_READ(__m);"
                    elif backend == "LLVM":
                        marker = b"call void @__lang_read_mark(ptr %__map_read_p) ; map-iter-read"
                    else:
                        functions = list(re.finditer(rb"\(func \$mere_map_[^\s]+_iter ", code))
                        if len(functions) != 1:
                            raise RuntimeError(f"{name}: expected one Wasm iterator")
                        start = functions[0].start()
                        end = code.find(b"\n  (func ", start)
                        body = code[start:end if end >= 0 else len(code)]
                        markers = re.findall(rb"\(call \$mere_map_read [^\n]+;; map-owner", body)
                        if len(markers) != 1:
                            raise RuntimeError(f"{name}: expected one Wasm iterator read")
                        marker = markers[0]
                        # Other Map readers retain their guards.
                        body = body.replace(marker, b"")
                        changed = code[:start] + body + (code[end:] if end >= 0 else b"")
                    if backend != "Wasm":
                        if code.count(marker) != 1:
                            raise RuntimeError(f"{name}: {backend}: expected one iterator entry mark")
                        changed = code.replace(marker, b"")
                elif case.control == "linear-get-fail":
                    if backend != "Wasm":
                        continue
                    functions = list(re.finditer(rb"\(func \$mere_map_[^\s]+_get ", code))
                    if len(functions) != 1:
                        raise RuntimeError(f"{name}: expected one Wasm lookup")
                    start = functions[0].start()
                    end = code.index(b"\n  (func ", start)
                    body = code[start:end]
                    marker = b"(call $__lang_fail (global.get $__lang_mapget_msg))"
                    if body.count(marker) != 1:
                        raise RuntimeError(f"{name}: expected one catchable lookup failure")
                    changed = code[:start] + body.replace(marker, b"(unreachable)") + code[end:]
                elif case.control.startswith("callback-"):
                    if backend != "Wasm":
                        continue
                    stage = case.control.removeprefix("callback-")
                    marker = ("(if (global.get $__lang_fail_flag) (then (return (i64.extend_i32_u (global.get $__lang_fail_sentinel))))) "
                              f";; map-iter-{stage}-fail").encode()
                    if code.count(marker) != 1:
                        raise RuntimeError(f"{name}: expected one callback failure boundary")
                    changed = code.replace(marker, b"")
                elif backend == "C":
                    marker = f"__LANG_READ(v); /* {case.control}-read */".encode()
                    if not code.count(marker):
                        raise RuntimeError(f"{name}: missing carry read mark")
                    changed = code.replace(marker, b"")
                else:
                    continue
                poisoned = wasm(changed) if backend == "Wasm" else native(changed, backend)
                if case.control in {"linear-get-fail", "callback-key"}:
                    valid = poisoned[0] != 0
                elif case.control == "callback-value":
                    valid = poisoned[0] == 0 and not poisoned[2] and b"callback-failed:" in poisoned[1] and poisoned != expected
                else:
                    valid = poison_exposes(poisoned, expected)
                if not valid:
                    raise RuntimeError(f"POISON {name}: {backend} did not expose the changed read: {poisoned!r}")
                controls += 1
                checks += 1
                print(f"  ok    POISON {backend} {name}", flush=True)
            print(f"  ok    {name}: {', '.join(case.backends)}", flush=True)
    assert controls == (31 if args.poison else 0), f"control coverage changed: {controls}"
    assert checks == sum(len(c.backends) for c in cases.values()) + controls
    print(f"map_read: ok ({len(cases)} fixtures; {checks} checks)")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.TimeoutExpired, AssertionError, KeyError) as error:
        raise SystemExit(f"map_read: FAIL {error}")

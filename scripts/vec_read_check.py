#!/usr/bin/env python3
"""Check Vec read boundaries against explicit results on every supported backend."""
import argparse
from dataclasses import dataclass
from pathlib import Path
import shutil
import subprocess
import tempfile

from rv_builder_owner_check import checked, run_suite
from rv_vec_owner_check import CC, MERE, ROOT, execute


ALL = ("interpreter", "C", "LLVM", "Wasm")
PREFIX = "let launch = fn (f: unit -> unit) -> spawn f;\n"


@dataclass
class Case:
    source: str
    expected: bytes
    backends: tuple = ALL
    rv: bool = True
    mark: str = ""


def setup(full, kind="int"):
    value = {"int": "65", "str": '"a"', "float": "1.0"}[kind]
    seed = f"vec_push v {value}" if full else "()"
    return PREFIX + f"""let mk = fn () -> let v = vec_new () in let _ = (if false then vec_push v {value} else ()) in let _ = {seed} in v;
let v = mk ();
let results = channel_new ();
"""


def fixtures():
    cases = {}
    # Each expression returns an observable scalar. The expected result is
    # independent of all backends, including C, which once missed empty reads.
    reads = {
        "len": ("vec_len v", True, ""),
        "generic_len": ("len v", True, ""),
        "get": ('try_or (fn () -> vec_get v 0) (-1)', True, ""),
        "get_negative": ('try_or (fn () -> vec_get v (-1)) (-1)', True, ""),
        "get_past": ('try_or (fn () -> vec_get v 99) (-1)', True, ""),
        "iter": ("let _ = vec_iter v (fn x -> channel_send results x) in 0", True, "iter"),
        "fold": ("vec_fold v 0 (fn a -> fn x -> a + x)", True, "fold"),
        "list": ("list_sum (vec_to_list v)", True, "list"),
        "owned": ("let o = vec_to_owned v in owned_vec_len o", True, "to-owned"),
        "bytes": ("bytes_len (bytes_of_vec v)", True, "bytes"),
        "map": ("vec_len (vec_map v (fn x -> x + 1))", False, "map"),
        "filter": ("vec_len (vec_filter v (fn x -> true))", False, "filter"),
        "concat_a": ("vec_len (vec_concat v (vec_new ()))", False, "concat-a"),
        "concat_b": ("vec_len (vec_concat (vec_new ()) v)", False, "concat-b"),
        "concat_alias": ("vec_len (vec_concat v v)", False, ""),
        "show": ("str_len (show v)", True, ""),
        "json": ("str_len (to_json v)", True, ""),
    }
    for full in (False, True):
        state = "full" if full else "empty"
        for op, (expr, rv, mark) in reads.items():
            size = int(full)
            value = {
                "get": 65 if full else -1, "get_negative": -1, "get_past": -1,
                "iter": 0, "fold": 65 * size, "list": 65 * size,
                "concat_alias": size * 2, "show": 7 if full else 5,
                "json": 4 if full else 2,
            }.get(op, size)
            source = setup(full) + f"""let h = launch (fn () -> channel_send results ({expr}));
let _ = join h;
"""
            if op == "iter" and full:
                source += "let _ = print_int (channel_recv results);\n"
            source += f"""let _ = print_int (channel_recv results);
let _ = print (try_or (fn () -> let _ = vec_push v 90 in "allowed") "shared");
print_int (vec_len v)
"""
            expected = ("65\n" if op == "iter" and full else "") + f"{value}\nshared\n{size}\n"
            backends = ("interpreter", "C") if op in {"show", "json"} else ALL
            cases[f"read_{state}_{op}"] = Case(source, expected.encode(), backends, rv, mark)
        for op, expr in {
            "bytes_alias": "let f = bytes_of_vec in bytes_len (f v)",
            "owned_alias": "let f = vec_to_owned in owned_vec_len (f v)",
            "list_alias": "let f = vec_to_list in list_sum (f v)",
        }.items():
            value = 65 * int(full) if op == "list_alias" else int(full)
            source = setup(full) + f"""let h = launch (fn () -> channel_send results ({expr}));
let _ = join h;
let _ = print_int (channel_recv results);
print (try_or (fn () -> let _ = vec_push v 90 in "allowed") "shared")
"""
            backends = ALL if op == "bytes_alias" else ("interpreter",)
            cases[f"read_{state}_{op}"] = Case(source, f"{value}\nshared\n".encode(), backends, op == "bytes_alias")
            wrapped = source.replace("let f = bytes_of_vec", "let f = fn a -> bytes_of_vec a").replace("let f = vec_to_owned", "let f = fn a -> vec_to_owned a").replace("let f = vec_to_list", "let f = fn a -> vec_to_list a")
            cases[f"wrapper_{state}_{op}"] = Case(wrapped, f"{value}\nshared\n".encode())
        # Storage-independent results may cross a thread boundary without
        # freezing their source. Mutable results have a separate owner word.
        for op, expr, observe in (
            ("bytes", "bytes_of_vec v", "bytes_len snapshot * 100 + (if bytes_len snapshot == 0 then 0 else bytes_get snapshot 0)"),
            ("list", "vec_to_list v", "list_len snapshot * 100 + list_sum snapshot"),
            ("map", "vec_map v (fn x -> x + 1)", "vec_len snapshot * 100 + (if vec_len snapshot == 0 then 0 else vec_get snapshot 0)"),
            ("filter", "vec_filter v (fn x -> true)", "vec_len snapshot * 100 + (if vec_len snapshot == 0 then 0 else vec_get snapshot 0)"),
            ("concat", "vec_concat v (vec_new ())", "vec_len snapshot * 100 + (if vec_len snapshot == 0 then 0 else vec_get snapshot 0)"),
        ):
            source = setup(full) + f"""let snapshot = {expr};
let _ = {"vec_set v 0 77" if full else "()"};
let _ = vec_push v 90;
let h = launch (fn () -> channel_send results ({observe}));
let _ = join h;
let _ = print_int (channel_recv results);
let _ = vec_push v 91;
print_int (vec_len v)
"""
            value = (166 if op == "map" else 165) if full else 0
            cases[f"snapshot_{state}_{op}"] = Case(source, f"{value}\n{int(full)+2}\n".encode(), rv=op in {"bytes", "list"})
        # Creating the partial in a foreign thread must not inspect storage.
        # Complete it only after the owner writes, and observe the new value.
        for op, partial, apply, expected in (
            ("get", "vec_get v", "partial 0", 65 if full else 90),
            ("map", "vec_map v", "vec_len (partial (fn x -> x))", int(full)+1),
            ("filter", "vec_filter v", "vec_len (partial (fn x -> true))", int(full)+1),
            ("fold", "vec_fold v 0", "partial (fn a -> fn x -> a + x)", 65*int(full)+90),
            ("iter", "vec_iter v", "let _ = partial (fn x -> ()) in 0", 0),
            ("concat", "vec_concat v", "vec_len (partial (vec_new ()))", int(full)+1),
        ):
            source = setup(full) + f"""let ready = channel_new ();
let go = channel_new ();
let h = launch (fn () ->
  let partial = {partial} in
  let _ = channel_send ready 0 in
  let _ = channel_recv go in
  channel_send results ({apply}));
let _ = channel_recv ready;
let _ = print (try_or (fn () -> let _ = vec_push v 90 in "owner-ok") "early-read");
let _ = channel_send go 0;
let _ = join h;
let _ = print_int (channel_recv results);
print (try_or (fn () -> let _ = vec_push v 91 in "allowed") "shared")
"""
            cases[f"partial_{state}_{op}"] = Case(source, f"owner-ok\n{expected}\nshared\n".encode(), ("interpreter",), False)
            wrapped = source.replace(f"let partial = {partial} in", f"let partial = fn a -> {partial} a in")
            cases[f"wrapper_partial_{state}_{op}"] = Case(wrapped, f"owner-ok\n{expected}\nshared\n".encode(), rv=op in {"get", "iter", "fold"})
        for op, expr in {
            "write_file": 'let _ = write_file_bytes "output.bin" v in 0',
            "pwrite": 'let f = file_openrw "output.bin" in let n = file_pwrite f 0 v in let _ = file_close f in n',
        }.items():
            source = setup(full) + f"""let h = launch (fn () -> channel_send results ({expr}));
let _ = join h;
let _ = print_int (channel_recv results);
let _ = print (try_or (fn () -> let _ = vec_push v 90 in "allowed") "shared");
let b = read_bytes "output.bin";
let _ = print_int (bytes_len b);
print_int (if bytes_len b == 0 then 0 else bytes_get b 0)
"""
            # The Node Wasm worker bootstrap does not supply file imports.
            # Test its supported non-I/O reads above; file reads run on the
            # interpreter, native backends and RISC-V instead of hanging a worker.
            cases[f"read_{state}_{op}"] = Case(source, f"{int(full) if op == 'pwrite' else 0}\nshared\n{int(full)}\n{65*int(full)}\n".encode(), ("interpreter", "C", "LLVM"), mark="write-file" if op == "write_file" else "pwrite")
    for full in (False, True):
        for valid in (False, True) if full else (False,):
            expr = 'f64x2_reduce_add (f64x2_load v 0)' if valid else 'f64x2_reduce_add (f64x2_load v 99)'
            source = setup(full, "float")
            if full:
                source += "let _ = vec_push v 2.0;\n"
            source += f"""let h = launch (fn () -> channel_send results (try_or (fn () -> let _ = {expr} in "read-ok") "read-failed"));
let _ = join h;
let _ = print (channel_recv results);
print (try_or (fn () -> let _ = vec_push v 9.0 in "allowed") "shared")
"""
            cases[f"simd_{full}_{valid}"] = Case(source, ("read-ok\nshared\n" if valid else "read-failed\nshared\n").encode())
    for op, expr in {
        "map": 'vec_map v (fn x -> if x == 65 then fail "callback" else x)',
        "filter": 'vec_filter v (fn x -> fail "callback")',
    }.items():
        source = setup(True) + f"""let h = launch (fn () -> channel_send results (try_or (fn () -> let _ = {expr} in "unexpected") "callback-failed"));
let _ = join h;
let _ = print (channel_recv results);
print (try_or (fn () -> let _ = vec_push v 90 in "allowed") "shared")
"""
        cases[f"callback_failure_{op}"] = Case(source, b"callback-failed\nshared\n", rv=False)
    for op, expr in {"map": 'vec_map v (fn x -> x ++ "!")', "filter": 'vec_filter v (fn x -> x == "a")', "concat": 'vec_concat v v'}.items():
        source = setup(True, "str") + f"""let h = launch (fn () -> let w = {expr} in channel_send results (vec_get w 0));
let _ = join h;
let _ = print (channel_recv results);
print (try_or (fn () -> let _ = vec_push v "b" in "allowed") "shared")
"""
        cases[f"typed_{op}"] = Case(source, ("a!\nshared\n" if op == "map" else "a\nshared\n").encode(), rv=False)
    # vec_to_owned must copy both the slots and the ownership header. A
    # foreign read of the source may not freeze the separately owned result.
    cases["owned_copy"] = Case(PREFIX + """let v = vec_new ();
let _ = vec_push v 65;
let o = vec_to_owned v;
let _ = vec_set v 0 66;
let _ = owned_vec_push o 67;
let h = launch (fn () -> let _ = vec_len v in ());
let _ = join h;
let _ = owned_vec_push o 68;
let _ = print_int (owned_vec_get o 0);
let _ = print_int (owned_vec_len o);
print_int (vec_get v 0)
""", b"65\n3\n66\n")
    cases["metadata"] = Case(setup(False) + """let h = launch (fn () -> let _ = vec_bytes v in ());
let _ = join h;
let _ = vec_push v 90;
print_int (vec_get v 0)
""", b"90\n")
    # Each argument and callback executes once. The calls count and the data
    # are checked separately from ownership, so a guard cannot duplicate work.
    cases["evaluation"] = Case("""let v = vec_new ();
let _ = vec_push v 1;
let _ = vec_push v 2;
let calls = vec_new ();
let arg = fn () -> let _ = vec_push calls 1 in v;
let make = fn () -> let _ = vec_push calls 2 in fn x -> let _ = vec_push calls 3 in x + 10;
let a = vec_map (arg ()) (make ());
let b = vec_filter (arg ()) (let _ = vec_push calls 4 in fn x -> let _ = vec_push calls 5 in true);
let c = vec_concat (arg ()) (arg ());
let _ = print_int (vec_len calls);
let _ = print_int (vec_get a 0 + vec_get a 1);
let _ = print_int (vec_len b);
print_int (vec_len c)
""", b"10\n23\n2\n4\n", rv=False)
    return cases


def outcome(result):
    return result.returncode, result.stdout, result.stderr


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--poison", action="store_true")
    parser.add_argument("--rv-only", action="store_true")
    args = parser.parse_args()
    cases = fixtures()
    assert len(cases) == 95 and sum(c.rv for c in cases.values()) == 51, "fixture catalogue changed"
    assert sum(len(c.backends) for c in cases.values()) == 320, "backend coverage changed"
    if args.rv_only:
        selected = {k: v.source for k, v in cases.items() if v.rv}
        expected = {k: v.expected for k, v in cases.items() if v.rv}
        poisons = [(k, ["__vec_read"]) for k in ("read_empty_owned", "read_full_bytes", "wrapper_partial_empty_get")]
        run_suite("vec_read", selected, poisons,
                  'let v = vec_new (); print_int (vec_len v)\n',
                  ["__vec_read", "__vec_track"], args.poison,
                  poison_check=lambda case, actual, ref: actual[0] == 0 and b"allowed\n" in actual[1] and actual != ref,
                  expected_outputs=expected)
        return
    for tool in (CC, "clang", "wat2wasm", "node"):
        if not shutil.which(tool):
            raise RuntimeError(f"required tool missing: {tool}")
    checks = 0
    with tempfile.TemporaryDirectory(prefix="vec-read-") as directory:
        tmp = Path(directory)

        def native(code, backend):
            suffix = "c" if backend == "C" else "ll"
            (tmp / f"case.{suffix}").write_bytes(code)
            checked([CC if backend == "C" else "clang", "-O2", "-w", f"case.{suffix}", "-o", "case", "-lm", "-lpthread"], tmp)
            return outcome(execute([tmp / "case"], tmp))

        def wasm(wat):
            (tmp / "module.wat").write_bytes(wat)
            checked(["wat2wasm", "--enable-tail-call", "--enable-threads", "module.wat", "-o", "module.wasm"], tmp)
            return outcome(execute(["node", ROOT / "scripts/run_wasm.js", tmp / "module.wasm"], tmp))

        for name, case in cases.items():
            file = tmp / "case.mere"
            file.write_text(case.source)
            expected = (0, case.expected, b"")
            for backend in case.backends:
                # Remove output left by another backend: an empty write must
                # create an empty file, rather than inherit a previous result.
                (tmp / "output.bin").unlink(missing_ok=True)
                if backend == "interpreter":
                    actual = outcome(execute([MERE, file], tmp))
                else:
                    flag = {"C": "-c", "LLVM": "-ll", "Wasm": "-w"}[backend]
                    code = checked([MERE, flag, file], tmp)
                    actual = wasm(code) if backend == "Wasm" else native(code, backend)
                if actual != expected:
                    raise RuntimeError(f"{name}: {backend}: {actual!r}, expected {expected!r}")
                checks += 1
                # Empty inputs isolate the operation's own entry guard from
                # per-element get guards. The existing C gate covers bytes
                # and to-owned; this gate adds the LLVM to-owned control.
                control = (args.poison and case.mark and "empty" in name and
                           ((backend == "C" and case.mark in {"map", "filter", "concat-a", "concat-b", "write-file", "pwrite"}) or
                            (backend == "LLVM" and case.mark in {"map", "filter", "concat-a", "concat-b", "to-owned", "iter", "fold", "list"})))
                if control:
                    if backend == "C":
                        var = "__va" if case.mark == "concat-a" else "__vb" if case.mark == "concat-b" else "v" if case.mark in {"write-file", "pwrite"} else "__vc"
                        mark = f"__LANG_READ({var}); /* vec-{case.mark}-read */".encode()
                    else:
                        var = "__vec_read1" if case.mark == "concat-b" else "__vec_read0"
                        mark = f"call void @__lang_read_mark(ptr %{var}) ; vec-{case.mark}-read".encode()
                    if code.count(mark) != 1:
                        raise RuntimeError(f"{name}: {backend}: expected one entry mark")
                    poisoned = native(code.replace(mark, b""), backend)
                    if poisoned[0] or poisoned[2] or b"allowed\n" not in poisoned[1] or poisoned == expected:
                        raise RuntimeError(f"POISON {name}: {backend} did not expose the missing read guard: {poisoned!r}")
                    checks += 1
                    print(f"  ok    POISON {backend} {name}", flush=True)
                if args.poison and backend == "Wasm" and "empty" in name and case.mark in {"map", "filter", "concat-a", "concat-b", "to-owned"}:
                    helper = {"map": "mere_vec_map", "filter": "mere_vec_filter",
                              "concat-a": "mere_vec_concat", "concat-b": "mere_vec_concat",
                              "to-owned": "mere_vec_clone"}[case.mark]
                    var = {"concat-a": "a8", "concat-b": "b8", "to-owned": "src8"}.get(case.mark, "v8")
                    start = code.index(f"(func ${helper} ".encode())
                    end = code.index(b"\n  (func ", start)
                    body = code[start:end]
                    mark = f"(call $mere_vec_read (local.get ${var})) ;; vec-owner".encode()
                    if body.count(mark) != 1:
                        raise RuntimeError(f"{name}: Wasm: expected one entry mark")
                    poisoned = wasm(code[:start] + body.replace(mark, b"") + code[end:])
                    if poisoned[0] or poisoned[2] or b"allowed\n" not in poisoned[1] or poisoned == expected:
                        raise RuntimeError(f"POISON {name}: Wasm did not expose the missing read guard: {poisoned!r}")
                    checks += 1
                    print(f"  ok    POISON Wasm {name}", flush=True)
            print(f"  ok    {name}: {', '.join(case.backends)}", flush=True)
        expected_checks = sum(len(c.backends) for c in cases.values()) + (19 if args.poison else 0)
        assert checks == expected_checks, f"expected {expected_checks} checks, ran {checks}"
        print(f"vec_read: ok ({len(cases)} fixtures; {checks} checks)")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.TimeoutExpired, AssertionError, KeyError) as error:
        raise SystemExit(f"vec_read: FAIL {error}")

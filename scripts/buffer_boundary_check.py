#!/usr/bin/env python3
"""Check buffer reads, writes and freezing against explicit expected results."""
import argparse
from dataclasses import dataclass
from pathlib import Path
import re
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
    control: str = ""


def fixtures():
    cases = {}

    def add(name, source, expected, standalone=False, **options):
        assert name not in cases
        cases[name] = Case(("" if standalone else PREFIX) + source, expected.encode(), **options)

    for ctor in ("new", "bytes"):
        for full in (False, True):
            state = "full" if full else "empty"
            n = int(full)
            make = (f"let b = bytebuf_new {n} in let _ = "
                    + ("bytebuf_set b 0 65" if full else "()") + " in b"
                    if ctor == "new" else f'bytebuf_of_bytes (bytes_of_str "{"A" if full else ""}")')
            setup = f"let mk = fn () -> {make};\nlet b = mk ();\n"
            observe = ('let _ = print_int (bytebuf_len b);\n'
                       'print_int (if bytebuf_len b == 0 then 0 else bytebuf_get b 0)\n')
            for op, expr, value in (
                ("len", "bytebuf_len b", str(n)),
                ("get", 'try_or (fn () -> bytebuf_get b 0) (-1)', "65" if full else "-1"),
                ("negative", 'try_or (fn () -> bytebuf_get b (-1)) (-1)', "-1"),
                ("past", 'try_or (fn () -> bytebuf_get b 99) (-1)', "-1"),
                ("snapshot", 'let s = bytes_of_bytebuf b in bytes_len s * 100 + (if bytes_len s == 0 then 0 else bytes_get s 0)', "165" if full else "0"),
            ):
                control = (f"read:bytebuf_{'get' if op == 'negative' else op}" if op != "snapshot"
                           else "read:bytes_of_bytebuf") if ctor == "new" and not full and op in {"len", "negative", "snapshot"} else ""
                add(f"bb_{ctor}_{state}_read_{op}", setup + f"""let results = channel_new ();
let h = launch (fn () -> channel_send results ({expr}));
let _ = join h;
let _ = print_int (channel_recv results);
let _ = print (try_or (fn () -> let _ = bytebuf_push b 9 in "allowed") "shared");
""" + observe, f"{value}\nshared\n{n}\n{65*n}\n", control=control)
            for op, expr in (("push", "bytebuf_push b 99"), ("set", "bytebuf_set b 0 99"),
                             ("negative", "bytebuf_set b (-1) 99"), ("past", "bytebuf_set b 99 99")):
                control = f"write:bytebuf_{op}" if ctor == "new" and full and op in {"push", "set"} else ""
                add(f"bb_{ctor}_{state}_foreign_{op}", setup + f"""let results = channel_new ();
let h = launch (fn () -> channel_send results (try_or (fn () -> let _ = {expr} in "allowed") "foreign"));
let _ = join h;
let _ = print (channel_recv results);
let _ = bytebuf_push b 7;
""" + observe, f"foreign\n{n+1}\n{65 if full else 7}\n", control=control)
                add(f"bb_{ctor}_{state}_shared_{op}", setup + f"""let h = launch (fn () -> let _ = bytebuf_len b in ());
let _ = join h;
let _ = print (try_or (fn () -> let _ = {expr} in "allowed") "shared");
""" + observe, f"shared\n{n}\n{65*n}\n")
            add(f"bb_{ctor}_{state}_owner", setup + """let _ = print_int (try_or (fn () -> bytebuf_get b (-1)) (-1));
let snapshot = bytes_of_bytebuf b;
let _ = bytebuf_push b 300;
let _ = print_int (bytes_len snapshot);
""" + observe, f"-1\n{n}\n{n+1}\n{65 if full else 44}\n")
            add(f"bb_{ctor}_{state}_snapshot", setup + """let snapshot = bytes_of_bytebuf b;
let _ = bytebuf_push b 7;
let results = channel_new ();
let h = launch (fn () -> channel_send results (bytes_len snapshot * 100 + (if bytes_len snapshot == 0 then 0 else bytes_get snapshot 0)));
let _ = join h;
let _ = print_int (channel_recv results);
let _ = bytebuf_push b 9;
""" + observe, f"{165*n}\n{n+2}\n{65 if full else 7}\n")
            for direct in (False, True):
                partial = "bytebuf_get b" if direct else "fn i -> bytebuf_get b i"
                add(f"bb_{ctor}_{state}_partial_{'builtin' if direct else 'wrapper'}", setup + f"""let ready = channel_new ();
let go = channel_new ();
let results = channel_new ();
let h = launch (fn () -> let partial = {partial} in
  let _ = channel_send ready 0 in let _ = channel_recv go in channel_send results (partial 0));
let _ = channel_recv ready;
let _ = print (try_or (fn () -> let _ = bytebuf_push b 7 in "owner-ok") "early-read");
let _ = channel_send go 0;
let _ = join h;
let _ = print_int (channel_recv results);
print (try_or (fn () -> let _ = bytebuf_push b 9 in "allowed") "shared")
""", f"owner-ok\n{65 if full else 7}\nshared\n",
                    backends=("interpreter",) if direct else ALL, rv=not direct)

    for full in (False, True):
        state = "full" if full else "empty"
        n = 2 * int(full)
        text = "ab" if full else ""
        setup = f'let mk = fn () -> let b = strbuf_new () in let _ = strbuf_push b "{text}" in b;\nlet b = mk ();\n'
        for op, expr, value in (("len", "str_of_int (strbuf_len b)", str(n)),
                                ("generic_len", "str_of_int (len b)", str(n)),
                                ("snapshot", "strbuf_to_str b", text)):
            control = f"read:strbuf_{'to_str' if op == 'snapshot' else 'len'}" if not full and op != "generic_len" else ""
            add(f"sb_{state}_read_{op}", setup + f"""let results = channel_new ();
let h = launch (fn () -> channel_send results ({expr}));
let _ = join h;
let _ = print (channel_recv results);
let _ = print (try_or (fn () -> let _ = strbuf_push b "x" in "allowed") "shared");
print (strbuf_to_str b)
""", f"{value}\nshared\n{text}\n", control=control)
        for op, value in (("push", "x"), ("empty_push", "")):
            add(f"sb_{state}_foreign_{op}", setup + f"""let results = channel_new ();
let h = launch (fn () -> channel_send results (try_or (fn () -> let _ = strbuf_push b "{value}" in "allowed") "foreign"));
let _ = join h;
let _ = print (channel_recv results);
let _ = strbuf_push b "!";
print (strbuf_to_str b)
""", f"foreign\n{text}!\n", control="write:strbuf_push" if full and op == "push" else "")
        add(f"sb_{state}_snapshot", setup + """let snapshot = strbuf_to_str b;
let _ = strbuf_push b (str_repeat "x" 80);
let results = channel_new ();
let h = launch (fn () -> channel_send results snapshot);
let _ = join h;
let _ = print (channel_recv results);
let _ = strbuf_push b "!";
print_int (strbuf_len b)
""", f"{text}\n{n+81}\n")
        add(f"sb_{state}_owner", setup + """let _ = print_int (len b);
let snapshot = strbuf_to_str b;
let _ = strbuf_push b "A🦊";
let _ = print snapshot;
print_int (strbuf_len b)
""", f"{n}\n{text}\n{n+5}\n")
        for direct in (False, True):
            saved = "strbuf_push b" if direct else "fn s -> strbuf_push b s"
            add(f"sb_{state}_saved_{'builtin' if direct else 'wrapper'}", setup + f"""let saved = {saved};
let h = launch (fn () -> let _ = strbuf_to_str b in ());
let _ = join h;
let _ = print (try_or (fn () -> let _ = saved "bad" in "allowed") "shared");
print (strbuf_to_str b)
""", f"shared\n{text}\n", backends=("interpreter",) if direct else ALL, rv=not direct)

    frozen = "lb_push: the builder was already turned into a list by lb_to_list"
    for full in (False, True):
        state = "full" if full else "empty"
        n = int(full)
        setup = ("let mk = fn () -> let b = lb_new () in let _ = (if false then lb_push b 1 else ()) in let _ = "
                 + ("lb_push b 1" if full else "()") + " in b;\nlet b = mk ();\n")
        observe = 'let xs = lb_to_list b;\nlet _ = print_int (list_sum xs);\nprint_int (list_len (lb_to_list b))\n'
        for op, expr in (("push", "lb_push b 9"), ("to_list", "lb_to_list b")):
            add(f"lb_{state}_foreign_{op}", setup + f"""let results = channel_new ();
let h = launch (fn () -> channel_send results (try_or (fn () -> let _ = {expr} in "allowed") "foreign"));
let _ = join h;
let _ = print (channel_recv results);
let _ = print (try_or (fn () -> let _ = lb_push b 2 in "owner-ok") "owner-blocked");
""" + observe, f"foreign\nowner-ok\n{n+2}\n{n+1}\n", control=f"write:lb_{op}" if not full else "")
            add(f"lb_{state}_frozen_foreign_{op}", setup + f"""let xs = lb_to_list b;
let results = channel_new ();
let h = launch (fn () -> channel_send results (try_or_msg (fn () -> let _ = {expr} in "allowed") (fn msg -> msg)));
let _ = join h;
let _ = print (channel_recv results);
let _ = print_int (list_sum xs);
print_int (list_len (lb_to_list b))
""", (frozen if op == "push" else "lb_to_list: a ListBuf made by one thread was written by another -- a ListBuf is not safe to share between threads; give it one owner thread and send it messages over a Channel") + f"\n{n}\n{n}\n")
        add(f"lb_{state}_freeze", setup + """let h = spawn (fn () -> ());
let _ = join h;
let xs = lb_to_list b;
let _ = print (try_or (fn () -> let _ = lb_push b 9 in "allowed") "frozen");
let _ = print_int (list_sum xs);
print_int (list_len (lb_to_list b))
""", f"frozen\n{n}\n{n}\n", control="freeze:lb_to_list" if not full else "")
        add(f"lb_{state}_region", setup + """let result = region R { try_or (fn () -> let _ = lb_push b 9 in "allowed") "region" };
let _ = print result;
if result == "allowed" then () else
  let _ = lb_push b 2 in
  let xs = lb_to_list b in
  let _ = print_int (list_sum xs) in print_int (list_len (lb_to_list b))
""", f"region\n{n+2}\n{n+1}\n", standalone=True, control="region:lb_push" if not full else "")
        add(f"lb_{state}_region_local", """let xs = region R {
  let b = lb_new () in
  let _ = (if false then lb_push b 1 else ()) in
""" + ("  let _ = lb_push b 1 in\n" if full else "") + """  let result = region Q { try_or (fn () -> let _ = lb_push b 9 in "allowed") "region" } in
  let _ = print result in let _ = lb_push b 2 in lb_to_list b };
let _ = print_int (list_sum xs);
print_int (list_len xs)
""", f"region\n{n+2}\n{n+1}\n", standalone=True)
        add(f"lb_{state}_region_conversion", setup + """let xs = region R { lb_to_list b };
let _ = print (try_or (fn () -> let _ = lb_push b 9 in "allowed") "frozen");
let _ = print_int (list_sum xs);
print_int (list_len (lb_to_list b))
""", f"frozen\n{n}\n{n}\n", standalone=True)
        add(f"lb_{state}_snapshot", setup + """let xs = lb_to_list b;
let results = channel_new ();
let h = launch (fn () -> channel_send results (list_sum xs + list_len xs));
let _ = join h;
let _ = print_int (channel_recv results);
let _ = print (try_or (fn () -> let _ = lb_push b 9 in "allowed") "frozen");
print_int (list_len (lb_to_list b))
""", f"{2*n}\nfrozen\n{n}\n")
        for direct in (False, True):
            saved = "lb_push b" if direct else "fn x -> lb_push b x"
            add(f"lb_{state}_saved_{'builtin' if direct else 'wrapper'}", setup + f"""let saved = {saved};
let xs = lb_to_list b;
let _ = print (try_or (fn () -> let _ = saved 9 in "allowed") "frozen");
print_int (list_sum xs)
""", f"frozen\n{n}\n", backends=("interpreter",) if direct else ALL, rv=not direct)

    # The operation starts after its arguments have been evaluated once, in
    # order. A failed argument must stop later effects and leave storage intact.
    setup = """let trace = strbuf_new ();
let note = fn (s: str) -> strbuf_push trace s;
let b = bytebuf_new 1;
"""
    for failed in (0, 1, 2, 3):
        args = ["b", "0", "65"]
        for i in range(3):
            if failed == i + 1:
                args[i] = f'if true then fail "argument" else ({args[i]})'
            args[i] = f'(let _ = note "{i+1}" in {args[i]})'
        call = "bytebuf_set " + " ".join(args)
        add(f"bb_argument_{'failure_'+str(failed) if failed else 'order'}", setup + f"""let result = try_or (fn () -> let _ = {call} in "complete") "caught";
let _ = print result;
let _ = print (strbuf_to_str trace);
print_int (bytebuf_get b 0)
""", (f"caught\n{'123'[:failed]}\n0\n" if failed else "complete\n123\n65\n"))
    add("sb_argument_failure", """let b = strbuf_new ();
let _ = print (try_or (fn () -> let _ = strbuf_push b (if true then fail "argument" else "bad") in "complete") "caught");
let _ = strbuf_push b "kept";
print (strbuf_to_str b)
""", "caught\nkept\n")
    add("lb_argument_failure", """let b = lb_new ();
let _ = print (try_or (fn () -> let _ = lb_push b (if true then fail "argument" else 9) in "complete") "caught");
let _ = lb_push b 7;
let xs = lb_to_list b;
let _ = print_int (list_sum xs);
print_int (list_len xs)
""", "caught\n7\n1\n")
    for direct in (False, True):
        saved = "bytebuf_set b 0" if direct else "fn x -> bytebuf_set b 0 x"
        add(f"bb_saved_{'builtin' if direct else 'wrapper'}", f"""let b = bytebuf_new 1;
let saved = {saved};
let h = launch (fn () -> let _ = bytebuf_len b in ());
let _ = join h;
let _ = print (try_or (fn () -> let _ = saved 99 in "allowed") "shared");
print_int (bytebuf_get b 0)
""", "shared\n0\n", backends=("interpreter",) if direct else ALL, rv=not direct)
    return cases


def outcome(result):
    return result.returncode, result.stdout, result.stderr


def changed_guard(code, backend, control):
    mode, op = control.split(":")
    if op.startswith("lb_") and backend != "Wasm":
        if mode == "region":
            if backend == "C":
                marker = b'if (__lang_region_live(__b->region) != __lang_current_region) __lang_fail_impl("lb_push: the builder belongs to a region that is not current");'
                n = code.count(marker)
                changed = code.replace(marker, b'')
            else:
                changed, n = re.subn(rb'br i1 %[^\n]+, label %(lb_ok[\w.]+), label %lb_other[\w.]+', rb'br label %\1', code)
        elif mode == "freeze":
            if backend == "C":
                changed, n = re.subn(rb'__b->frozen = 1;', b'__b->frozen = 0;', code)
            else:
                changed, n = re.subn(
                    rb'(?P<address>%[\w.]+)(?P<gep> = getelementptr %__lang_listbuf, ptr [^\n]+, i32 0, i32 4\n  store i32 )1(?P<tail>, ptr (?P=address))',
                    rb'\g<address>\g<gep>0\g<tail>', code)
        elif backend == "C":
            changed, n = re.subn(rb'__LANG_OWNED\(__b, "ListBuf", "' + op.encode() + rb'"\);', b'', code)
        else:
            changed, n = re.subn(rb'call void @__lang_owned\([^\n]*@\.own_listbuf_' + op.encode() + rb'[^\n]*\)', b'', code)
        if not n:
            raise RuntimeError(f"missing {backend} {control} boundary")
        return changed
    name = "mere_" + op
    if backend == "Wasm":
        start = code.index(f"(func ${name} ".encode())
        end = code.find(b"\n  (func ", start)
        end = len(code) if end < 0 else end
    elif backend == "LLVM":
        start = re.search(rb'^define [^\n]*@' + name.encode() + rb'\(', code, re.M).start()
        end = code.index(b'\n}', start) + 2
    else:
        match = re.search(rb'static [^;{}\n]+\b' + name.encode() + rb'\([^;{}\n]*\)\s*\{', code)
        start = match.start()
        end = match.end()
        depth = 1
        while depth:
            depth += (code[end] == ord('{')) - (code[end] == ord('}'))
            end += 1
    body = code[start:end]
    if backend == "C":
        pattern = rb'__LANG_READ\([^;]+\);' if mode == "read" else rb'__LANG_OWNED\([^;]+\);'
    elif backend == "LLVM":
        pattern = rb'call void @__lang_read_mark\([^\n]+\)' if mode == "read" else rb'call void @__lang_owned\([^\n]+\)'
    elif mode == "region":
        pattern = rb'\(if \(i32.ne \(i32.load offset=8 \(local.get \$b\)\) \(global.get \$__lang_region_depth\)\)\s*\(then \(return \(call \$__lang_fail \(i64.const \d+\)\)\)\)\)'
    elif mode == "freeze":
        pattern = rb'\(i32.store offset=12 \(local.get \$b\) \(i32.const 1\)\)'
    elif mode == "read":
        pattern = rb'\(call \$mere_(?:bytebuf|strbuf)_read [^\n]+;; buffer-owner'
    else:
        pattern = rb'\(if \(i32.eqz \(call \$mere_(?:bytebuf|strbuf|lb)_write [^\n]+;; (?:buffer|lb)-owner'
    if backend == "Wasm" and mode == "freeze":
        replacement = b'(i32.store offset=12 (local.get $b) (i32.const 0))'
    else:
        replacement = b''
    changed, n = re.subn(pattern, replacement, body)
    if n != 1:
        raise RuntimeError(f"expected one {backend} {control} boundary, found {n}")
    return code[:start] + changed + code[end:]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--poison", action="store_true")
    parser.add_argument("--rv-only", action="store_true")
    args = parser.parse_args()
    cases = fixtures()
    assert len(cases) == 116 and sum(c.rv for c in cases.values()) == 107, "fixture catalogue changed"
    assert sum(len(c.backends) for c in cases.values()) == 437, "backend coverage changed"
    if args.rv_only:
        selected = {k: c for k, c in cases.items() if c.rv}
        poisons = [
            ("bb_new_full_foreign_push", ["__vec_write_bytebuf_push", "__vec_write_vec_push"]),
            ("bb_new_empty_read_len", ["__vec_read"]),
            ("sb_empty_read_len", ["__sb_read"]),
            ("sb_full_foreign_push", ["__sb_write"]),
            ("lb_empty_foreign_push", ["__vec_write_lb_push", "__vec_write_vec_push", "__vec_read"]),
            ("lb_empty_foreign_to_list", ["__vec_write_lb_to_list", "__vec_write_vec_set", "__vec_read"]),
        ]
        run_suite("buffer_boundary", {k: c.source for k, c in selected.items()}, poisons,
                  'let b = bytebuf_new 0; let s = strbuf_new (); let l = lb_new (); let _ = lb_push l 1; print_int (bytebuf_len b + strbuf_len s + list_len (lb_to_list l))\n',
                  ["__vec_track", "__vec_read", "__vec_write_", "__sb_track", "__sb_read", "__sb_write"], args.poison,
                  expected_outputs={k: c.expected for k, c in selected.items()},
                  prelude_poisons=[("lb_empty_region", 'else if vec_get v 1 != __rv_rtw 1 then fail "lb_push: the builder belongs to a region that is not current"')])
        return
    for tool in (CC, "clang", "wat2wasm", "node"):
        if not shutil.which(tool):
            raise RuntimeError(f"required tool missing: {tool}")
    checks = controls = 0
    with tempfile.TemporaryDirectory(prefix="buffer-boundary-") as directory:
        tmp = Path(directory)

        def run(code, backend):
            if backend == "Wasm":
                (tmp / "module.wat").write_bytes(code)
                checked(["wat2wasm", "--enable-tail-call", "--enable-threads", "module.wat", "-o", "module.wasm"], tmp)
                return outcome(execute(["node", ROOT / "scripts/run_wasm.js", tmp / "module.wasm"], tmp))
            suffix = "c" if backend == "C" else "ll"
            (tmp / f"case.{suffix}").write_bytes(code)
            checked([CC if backend == "C" else "clang", "-O2", "-w", f"case.{suffix}", "-o", "case", "-lm", "-lpthread"], tmp)
            return outcome(execute([tmp / "case"], tmp))

        for name, case in cases.items():
            file = tmp / "case.mere"
            file.write_text(case.source)
            expected = (0, case.expected, b"")
            for backend in case.backends:
                if backend == "interpreter":
                    actual = outcome(execute([MERE, file], tmp))
                else:
                    code = checked([MERE, {"C": "-c", "LLVM": "-ll", "Wasm": "-w"}[backend], file], tmp)
                    actual = run(code, backend)
                if actual != expected:
                    raise RuntimeError(f"{name}: {backend}: {actual!r}; expected {expected!r}")
                checks += 1
                if args.poison and case.control and backend != "interpreter":
                    poisoned = run(changed_guard(code, backend, case.control), backend)
                    if poisoned[0] or poisoned[2] or b"allowed\n" not in poisoned[1] or poisoned == expected:
                        raise RuntimeError(f"POISON {name}: {backend}: removed boundary was not detected: {poisoned!r}")
                    checks += 1
                    controls += 1
                    print(f"  ok    POISON {backend} {name}", flush=True)
            print(f"  ok    {name}: {', '.join(case.backends)}", flush=True)
    assert checks == sum(len(c.backends) for c in cases.values()) + controls
    assert controls == (36 if args.poison else 0), "negative control coverage changed"
    print(f"buffer_boundary: ok ({len(cases)} fixtures; {checks} checks; {controls} negative controls)")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.TimeoutExpired, AssertionError, KeyError) as error:
        raise SystemExit(f"buffer_boundary: FAIL {error}")

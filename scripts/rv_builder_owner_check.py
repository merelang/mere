#!/usr/bin/env python3
"""Compare ByteBuf and ListBuf ownership with C on both RISC-V widths."""
import argparse
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile

from rv_vec_owner_check import execute, guest, MERE, CC

PREFIX = "let launch = fn (f: unit -> unit) -> spawn f;\n"


def fixtures():
    cases = {}
    for ctor in ("new", "bytes"):
        for seed in ("empty", "full"):
            n = 0 if seed == "empty" else 2
            expression = f"bytebuf_new {n}" if ctor == "new" else f'bytebuf_of_bytes (bytes_of_str "{("" if n == 0 else "ab")}")'
            setup = PREFIX + f"let mk = fn () -> {expression};\nlet b = mk ();\n"
            state = 'let snapshot = bytes_of_bytebuf b; let rec dump = fn (i: int) -> if i >= bytes_len snapshot then () else let _ = print_int (bytes_get snapshot i) in dump (i + 1); let _ = print_int (bytebuf_len b); dump 0\n'
            for op, expr in {"push": "bytebuf_push b 99", "set": "bytebuf_set b 0 99",
                             "set_negative": "bytebuf_set b (-1) 99", "set_past": "bytebuf_set b 999 99"}.items():
                catch = f'try_or_msg (fn () -> let _ = {expr} in "allowed") (fn msg -> msg)'
                cases[f"bb_foreign_{ctor}_{seed}_{op}"] = setup + f"""let results = channel_new ();
let h = launch (fn () -> channel_send results ({catch}));
let _ = join h;
let _ = print (channel_recv results);
let _ = print (try_or (fn () -> let _ = bytebuf_push b 7 in "owner-ok") "owner-blocked");
""" + state
                cases[f"bb_shared_{ctor}_{seed}_{op}"] = setup + f"""let h = launch (fn () -> let _ = bytebuf_len b in ());
let _ = join h;
let _ = print ({catch});
""" + state
            for op, expr in {"len": "bytebuf_len b", "get": "bytebuf_get b 0",
                             "get_negative": "bytebuf_get b (-1)", "get_past": "bytebuf_get b 999",
                             "snapshot": "bytes_of_bytebuf b"}.items():
                cases[f"bb_read_{ctor}_{seed}_{op}"] = setup + f"""let h = launch (fn () -> try_or (fn () -> let _ = {expr} in ()) ());
let _ = join h;
let _ = print (try_or_msg (fn () -> let _ = bytebuf_push b 99 in "allowed") (fn msg -> msg));
""" + state
    for seed in ("empty", "full"):
        initial = "()" if seed == "empty" else "lb_push b 1"
        setup = PREFIX + f"let mk = fn () -> let b = lb_new () in let _ = {initial} in b;\nlet b = mk ();\n"
        for op, expr in {"push": "lb_push b 9", "to_list": "lb_to_list b"}.items():
            cases[f"lb_foreign_{seed}_{op}"] = setup + f"""let results = channel_new ();
let h = launch (fn () -> channel_send results (try_or_msg (fn () -> let _ = {expr} in "allowed") (fn msg -> msg)));
let _ = join h;
let _ = print (channel_recv results);
let _ = print (try_or (fn () -> let _ = lb_push b 2 in "owner-ok") "owner-blocked");
let xs = lb_to_list b;
let _ = print_int (list_sum xs);
print_int (list_len xs)
"""
            cases[f"lb_frozen_{seed}_{op}"] = setup + f"""let xs = lb_to_list b;
let results = channel_new ();
let h = launch (fn () -> channel_send results (try_or_msg (fn () -> let _ = {expr} in "allowed") (fn msg -> msg)));
let _ = join h;
let _ = print (channel_recv results);
let _ = print_int (list_sum xs);
print_int (list_len (lb_to_list b))
"""
    cases["bb_snapshot"] = PREFIX + """let b = bytebuf_of_bytes (bytes_of_str "ab");
let frozen = bytes_of_bytebuf b;
let results = channel_new ();
let h = launch (fn () -> channel_send results (bytes_len frozen));
let _ = join h;
let _ = bytebuf_push b 99;
print_int (bytebuf_len b + channel_recv results)
"""
    cases["bb_local_growth"] = PREFIX + """let results = channel_new ();
let work = fn () ->
  let b = bytebuf_of_bytes (bytes_of_str "x") in
  let rec fill = fn (i: int) -> if i == 100 then () else let _ = bytebuf_push b (i + 256) in fill (i + 1) in
  let _ = fill 0 in let _ = bytebuf_set b 0 511 in
  bytebuf_len b + bytebuf_get b 0 + bytebuf_get b 100;
let h = launch (fn () -> channel_send results (work ()));
let own = work ();
let _ = join h;
print_int (own + channel_recv results)
"""
    cases["lb_local_growth"] = PREFIX + """let results = channel_new ();
let work = fn () ->
  let b = lb_new () in
  let rec fill = fn (i: int) -> if i == 40 then () else let _ = lb_push b (str_of_int i) in fill (i + 1) in
  let _ = fill 0 in
  let xs = lb_to_list b in
  let again = lb_to_list b in
  let failed = try_or (fn () -> let _ = lb_push b "bad" in 0) 7 in
  list_len xs + list_len again + failed;
let h = launch (fn () -> channel_send results (work ()));
let own = work ();
let _ = join h;
print_int (own + channel_recv results)
"""
    cases["lb_list_messages"] = PREFIX + """let b = lb_new ();
let _ = lb_push b 1;
let _ = lb_push b 2;
let xs = lb_to_list b;
let results = channel_new ();
let a = launch (fn () -> channel_send results (list_sum xs));
let c = launch (fn () -> channel_send results (list_len xs));
let _ = join a;
let _ = join c;
print_int (channel_recv results + channel_recv results + list_len (lb_to_list b))
"""
    cases["bb_nested"] = PREFIX + """let results = channel_new ();
let a = launch (fn () ->
  let b = bytebuf_new 1 in
  let child = launch (fn () -> channel_send results (try_or (fn () -> let _ = bytebuf_push b 99 in 0) 7)) in
  let _ = join child in let _ = bytebuf_push b 2 in channel_send results (bytebuf_len b));
let _ = join a;
print_int (channel_recv results + channel_recv results)
"""
    cases["lb_nested"] = PREFIX + """let results = channel_new ();
let a = launch (fn () ->
  let b = lb_new () in let _ = lb_push b 1 in
  let child = launch (fn () -> channel_send results (try_or (fn () -> let _ = lb_to_list b in 0) 7)) in
  let _ = join child in let _ = lb_push b 2 in channel_send results (list_sum (lb_to_list b)));
let _ = join a;
print_int (channel_recv results + channel_recv results)
"""
    cases["bb_par_map"] = """let b = bytebuf_new 1;
let run = fn (f: int -> int) -> par_map f [1, 2];
let xs = run (fn x -> let _ = bytebuf_get b 0 in x);
let failed = try_or (fn () -> let _ = bytebuf_push b 99 in 0) 7;
print_int (list_sum xs + failed)
"""
    cases["lb_par_map"] = """let b = lb_new ();
let run = fn (f: int -> int) -> par_map f [1, 2];
let xs = run (fn x -> try_or (fn () -> let _ = lb_push b x in 0) 7);
let _ = lb_push b 3;
print_int (list_sum xs + list_sum (lb_to_list b))
"""
    return cases


def checked(command, cwd, env=None):
    result = execute(command, cwd, env=env)
    if result.returncode:
        raise RuntimeError(f"{Path(command[0]).name} exited {result.returncode}: " + result.stderr.decode(errors="replace")[:500])
    return result.stdout


def run_suite(name, cases, poisons, plain, forbidden, poison):
    memu = Path(os.environ.get("MEMU", ""))
    if not (memu / "riscv-runc/rv32i_run.mere").is_file():
        raise RuntimeError("set MEMU to a memu checkout; both widths must run")
    with tempfile.TemporaryDirectory(prefix=name + "-") as directory:
        tmp = Path(directory)
        runners = {}
        for width in (32, 64):
            (tmp / "runner.c").write_bytes(checked([MERE, "-c", memu / f"riscv-runc/rv{width}i_run.mere"], tmp))
            runners[width] = tmp / f"rvrun{width}"
            checked([CC, "-O2", "-w", "runner.c", "-o", runners[width], "-lm"], tmp)
        references = {}
        checks = 0

        def build(case, width, env=None):
            flag = "-rv" if width == 32 else "-rv64"
            (tmp / "prog.bin").write_bytes(checked([MERE, flag, "--ram", "32", tmp / f"{case}.mere"], tmp, env))

        def run(width):
            return guest(execute([runners[width], "32"], tmp))

        for case, source in cases.items():
            (tmp / f"{case}.mere").write_text(source)
            (tmp / "ref.c").write_bytes(checked([MERE, "-c", tmp / f"{case}.mere"], tmp))
            checked([CC, "-O1", "-w", "ref.c", "-o", "ref", "-lm", "-lpthread"], tmp)
            result = execute([tmp / "ref"], tmp)
            expected = (result.returncode, result.stdout, result.stderr)
            if expected[0] or expected[2]:
                raise RuntimeError(f"{case}: unexpected C failure: {expected!r}")
            references[case] = expected
            for width in (32, 64):
                build(case, width)
                actual = run(width)
                if actual != expected:
                    raise RuntimeError(f"{case}: RV{width} differs from C: {actual!r} versus {expected!r}")
                checks += 1
            print(f"  ok    {case}: RV32 and RV64 match C", flush=True)
        if poison:
            for case, labels in poisons:
                for width in (32, 64):
                    build(case, width)
                    flag = "-rvg" if width == 32 else "-rv64g"
                    debug = checked([MERE, flag, "--ram", "32", tmp / f"{case}.mere"], tmp).decode()
                    base = int(re.search(r"load_base=(\d+)", debug)[1])
                    addresses = {label: int(address) - base for address, label in re.findall(r"^S (\d+) (\S+)$", debug, re.M)}
                    data = bytearray((tmp / "prog.bin").read_bytes())
                    for label in labels:
                        offset = addresses[label]
                        assert 0 <= offset <= len(data) - 4
                        assert data[offset:offset + 4] != struct.pack("<I", 0x8067)
                        data[offset:offset + 4] = struct.pack("<I", 0x8067)
                    (tmp / "prog.bin").write_bytes(data)
                    actual = run(width)
                    if actual[0] or b"allowed\n" not in actual[1] or actual == references[case]:
                        raise RuntimeError(f"POISON {case}: RV{width} remained green without {labels}")
                    checks += 1
                print(f"  ok    POISON {case}: removed {', '.join(labels)}", flush=True)
            prelude = checked([MERE, "--rv-prelude"], tmp).decode()
            changed = prelude.replace("__rv_rtw_set 81 next", "__rv_rtw_set 81 0")
            assert changed != prelude
            (tmp / "prelude.mere").write_text(changed)
            env = dict(os.environ, MERE_RV_PRELUDE_FILE=str(tmp / "prelude.mere"))
            case = poisons[0][0]
            for width in (32, 64):
                build(case, width, env)
                actual = run(width)
                if actual[0] or b"allowed\n" not in actual[1] or actual == references[case]:
                    raise RuntimeError("POISON duplicate identities remained green")
                checks += 1
            print("  ok    POISON duplicate logical identities", flush=True)
        (tmp / "plain.mere").write_text(plain)
        for flag in ("-rvg", "-rv64g"):
            debug = checked([MERE, flag, tmp / "plain.mere"], tmp)
            if any(label.encode() in debug for label in forbidden):
                raise RuntimeError("ownership helpers remain without green threads")
            checks += 1
        expected = len(cases) * 2 + 2 + ((len(poisons) * 2 + 2) if poison else 0)
        assert checks == expected, "some checks did not run"
        print(f"{name}: ok ({len(cases)} fixtures at both widths against C; {checks} checks)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--poison", action="store_true")
    args = parser.parse_args()
    cases = fixtures()
    assert len(cases) == 68, "fixture catalogue changed"
    poisons = [
        ("bb_foreign_new_full_push", ["__vec_write_bytebuf_push", "__vec_write_vec_push"]),
        ("bb_foreign_new_full_set", ["__vec_write_bytebuf_set", "__vec_write_vec_set", "__vec_read"]),
        ("lb_foreign_empty_push", ["__vec_write_lb_push", "__vec_write_vec_push", "__vec_read"]),
        ("lb_foreign_empty_to_list", ["__vec_write_lb_to_list", "__vec_write_vec_set", "__vec_read"]),
        ("bb_read_new_empty_len", ["__vec_read"]),
        ("bb_foreign_new_full_push", ["__vec_track"]),
        ("bb_foreign_bytes_full_push", ["__vec_track"]),
        ("lb_foreign_full_push", ["__vec_track"]),
    ]
    run_suite("rv_builder_owner", cases, poisons,
              'let b = bytebuf_new 1; let _ = bytebuf_set b 0 7; let l = lb_new (); let _ = lb_push l 1; print_int (list_len (lb_to_list l) + bytebuf_get b 0)\n',
              ["__vec_track", "__vec_read", "__vec_write_"], args.poison)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.TimeoutExpired, AssertionError, KeyError) as error:
        raise SystemExit(f"rv_builder_owner: FAIL {error}")

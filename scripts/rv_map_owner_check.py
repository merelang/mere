#!/usr/bin/env python3
"""Compare Map ownership with C on RV32 and RV64, with mutation controls."""
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
    keys = {
        "int": ("", "1", "2"),
        "bool": ("", "true", "false"),
        "str": ("", '\"kept\"', '\"added\"'),
        "tuple": ("", '(1, \"kept\")', '(2, \"added\")'),
        "record": ('type Key = { id: int, name: str };\n',
                   'Key { id = 1, name = \"kept\" }', 'Key { id = 2, name = \"added\" }'),
        "variant": ('type Key = A of int | B of str;\n', 'A 1', 'B \"added\"'),
    }
    writes = {
        "set": "map_set m KEY 9", "insert": "map_set m OTHER 9",
        "delete": "map_delete m KEY", "delete_absent": "map_delete m OTHER",
        "clear": "map_clear m", "recycle": "map_recycle m", "compact": "map_compact m",
    }
    reads = {
        "get": "map_get m KEY", "get_absent": "map_get m OTHER",
        "has": "map_has m KEY", "has_absent": "map_has m OTHER",
        "len": "map_len m", "generic_len": "len m",
        "iter": "map_iter m (fn k -> fn v -> ())",
    }
    for family, (decl, key, other) in keys.items():
        for seed in ("empty", "full"):
            initial = "()" if seed == "empty" else f"map_set m {key} 1"
            setup = decl + PREFIX + f"""let mk = fn () -> let m = map_new () in
  let _ = (if false then map_set m {key} 0 else ()) in let _ = {initial} in m;
let m = mk ();
"""
            # Avoid Map formatting, whose representation is backend-specific.
            state = f"let _ = print_int (map_len m); let _ = print_int (if map_has m {key} then map_get m {key} else 0); print_int (if map_has m {other} then map_get m {other} else 0)\n"
            for op, expr in writes.items():
                expr = expr.replace("OTHER", other).replace("KEY", key)
                catch = f'try_or_msg (fn () -> let _ = {expr} in "allowed") (fn msg -> msg)'
                cases[f"foreign_{family}_{seed}_{op}"] = setup + f"""let results = channel_new ();
let h = launch (fn () -> channel_send results ({catch}));
let _ = join h;
let _ = print (channel_recv results);
let _ = print (try_or (fn () -> let _ = map_set m {key} 1 in "owner-ok") "owner-blocked");
""" + state
                cases[f"shared_{family}_{seed}_{op}"] = setup + f"""let h = launch (fn () -> let _ = map_len m in ());
let _ = join h;
let _ = print ({catch});
""" + state
            for op, expr in reads.items():
                if op == "get" and seed == "empty":
                    continue
                expr = expr.replace("OTHER", other).replace("KEY", key)
                cases[f"read_{family}_{seed}_{op}"] = setup + f"""let h = launch (fn () -> let _ = try_or (fn () -> let _ = {expr} in ()) () in ());
let _ = join h;
let _ = print (try_or_msg (fn () -> let _ = map_set m {key} 9 in "allowed") (fn msg -> msg));
""" + state
    for step, expression in {"clear": "map_clear m", "recycle": "map_recycle m", "compact": "map_compact m"}.items():
        cases[f"preserve_{step}"] = PREFIX + f"""let results = channel_new ();
let h = launch (fn () ->
  let m = map_new () in
  let rec fill = fn (i: int) -> if i == 40 then () else let _ = map_set m (str_of_int i) (str_of_int i) in fill (i + 1) in
  let _ = fill 0 in let _ = map_delete m "1" in
  let _ = {expression} in let _ = map_set m "kept" "value" in
  let child = launch (fn () -> channel_send results (try_or_msg (fn () -> let _ = map_set m "kept" "bad" in "allowed") (fn msg -> msg))) in
  let _ = join child in channel_send results (map_get m "kept"));
let _ = join h;
let _ = print (channel_recv results);
print (channel_recv results)
"""
    cases["local_and_iteration"] = PREFIX + """let results = channel_new ();
let h = launch (fn () ->
  let m = map_new () in
  let rec fill = fn (i: int) -> if i == 40 then () else let _ = map_set m i (str_of_int i) in fill (i + 1) in
  let _ = fill 0 in let _ = map_delete m 1 in let _ = map_compact m in
  let _ = map_iter m (fn k -> fn v -> if k == 0 then map_set m 0 "kept" else ()) in
  let _ = channel_send results (map_get m 0) in
  let _ = map_clear m in let _ = map_recycle m in let _ = map_compact m in
  let _ = map_set m 2 "again" in channel_send results (map_get m 2));
let _ = join h;
let _ = print (channel_recv results);
print (channel_recv results)
"""
    cases["bytes_capacity"] = PREFIX + """let m = map_new ();
let _ = map_set m "kept" 1;
let h = launch (fn () -> let _ = map_bytes m in ());
let _ = join h;
let _ = map_set m "kept" 9;
print_int (map_get m "kept")
"""
    cases["higher_order"] = PREFIX + """let m = map_new ();
let _ = map_set m 1 1;
let results = channel_new ();
let apply = fn f -> f m;
let h = launch (fn () -> channel_send results (try_or_msg (fn () -> let _ = apply (fn m -> map_clear m) in "allowed") (fn msg -> msg)));
let _ = join h;
let _ = print (channel_recv results);
let _ = print_int (apply (fn m -> map_len m));
let h2 = launch (fn () -> let _ = apply (fn m -> map_len m) in ());
let _ = join h2;
print (try_or_msg (fn () -> let _ = apply (fn m -> map_recycle m) in "allowed") (fn msg -> msg))
"""
    cases["par_map"] = PREFIX + """let m = map_new ();
let _ = map_set m 1 1;
let run = fn (f: int -> str) -> par_map f [1, 2];
let xs = run (fn x -> try_or_msg (fn () -> let _ = map_set m x 9 in "allowed") (fn msg -> msg));
let _ = list_iter xs (fn s -> print s);
print_int (map_get m 1)
"""
    cases["identities"] = PREFIX + """let callbacks = channel_new ();
let ready = channel_new ();
let results = channel_new ();
let a = launch (fn () ->
  let m = map_new () in let _ = map_set m 1 1 in
  let _ = channel_send callbacks (fn () -> map_len m) in
  let _ = channel_recv ready in
  channel_send results (try_or (fn () -> let _ = map_set m 1 2 in 0) 7));
let b = launch (fn () -> let read = channel_recv callbacks in let _ = read () in channel_send ready ());
let _ = join a;
let _ = join b;
print_int (channel_recv results)
"""
    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--poison", action="store_true")
    args = parser.parse_args()
    memu = Path(os.environ.get("MEMU", ""))
    if not (memu / "riscv-runc/rv32i_run.mere").is_file():
        parser.error("set MEMU to a memu checkout; both widths must run")
    with tempfile.TemporaryDirectory(prefix="rv-map-owner-") as directory:
        tmp = Path(directory)
        runners = {}
        for width in (32, 64):
            (tmp / "runner.c").write_bytes(checked([MERE, "-c", memu / f"riscv-runc/rv{width}i_run.mere"], tmp))
            runners[width] = tmp / f"rvrun{width}"
            checked([CC, "-O2", "-w", "runner.c", "-o", runners[width], "-lm"], tmp)
        cases = fixtures()
        assert len(cases) == 254, "fixture catalogue changed"
        references = {}
        checks = 0

        def build(name, width, env=None):
            flag = "-rv" if width == 32 else "-rv64"
            (tmp / "prog.bin").write_bytes(checked_env([MERE, flag, "--ram", "32", tmp / f"{name}.mere"], tmp, env))

        def run(width):
            return guest(execute([runners[width], "32"], tmp))

        for name, source in cases.items():
            (tmp / f"{name}.mere").write_text(source)
            (tmp / "ref.c").write_bytes(checked([MERE, "-c", tmp / f"{name}.mere"], tmp))
            checked([CC, "-O1", "-w", "ref.c", "-o", "ref", "-lm", "-lpthread"], tmp)
            result = execute([tmp / "ref"], tmp)
            expected = (result.returncode, result.stdout, result.stderr)
            if expected[0] or expected[2]:
                raise RuntimeError(f"{name}: unexpected C failure: {expected!r}")
            references[name] = expected
            for width in (32, 64):
                build(name, width)
                actual = run(width)
                if actual != expected:
                    raise RuntimeError(f"{name}: RV{width} differs from C: {actual!r} versus {expected!r}")
                checks += 1
            print(f"  ok    {name}: RV32 and RV64 match C", flush=True)

        if args.poison:
            def remove_helper(name, width, labels):
                build(name, width)
                flag = "-rvg" if width == 32 else "-rv64g"
                debug = checked([MERE, flag, "--ram", "32", tmp / f"{name}.mere"], tmp).decode()
                base = int(re.search(r"load_base=(\d+)", debug)[1])
                addresses = {label: int(address) - base for address, label in re.findall(r"^S (\d+) (\S+)$", debug, re.M)}
                data = bytearray((tmp / "prog.bin").read_bytes())
                for label in labels:
                    offset = addresses[label]
                    assert 0 <= offset <= len(data) - 4
                    data[offset:offset + 4] = struct.pack("<I", 0x8067)
                (tmp / "prog.bin").write_bytes(data)

            poisons = [
                ("foreign_int_full_set", ["__map_write_map_set"]),
                ("foreign_str_full_delete", ["__map_write_map_delete"]),
                ("foreign_int_empty_clear", ["__map_write_map_clear_meta"]),
                ("foreign_str_full_recycle", ["__map_write_map_recycle"]),
                ("foreign_str_full_compact", ["__map_write_map_compact_meta"]),
                ("read_int_full_get", ["__map_read"]),
                ("read_str_empty_len", ["__map_read_meta"]),
                ("foreign_int_full_set", ["__map_track"]),
            ]
            for name, labels in poisons:
                for width in (32, 64):
                    remove_helper(name, width, labels)
                    actual = run(width)
                    if actual[0] or b"allowed\n" not in actual[1] or actual == references[name]:
                        raise RuntimeError(f"POISON {name}: RV{width} did not expose an allowed write: {actual!r}")
                    checks += 1
                print(f"  ok    POISON {name}: removed {', '.join(labels)}", flush=True)
            prelude = checked([MERE, "--rv-prelude"], tmp).decode()
            poisoned = prelude.replace("__rv_rtw_set 81 next", "__rv_rtw_set 81 0")
            assert poisoned != prelude
            (tmp / "prelude.mere").write_text(poisoned)
            env = dict(os.environ, MERE_RV_PRELUDE_FILE=str(tmp / "prelude.mere"))
            for width in (32, 64):
                build("foreign_int_full_set", width, env)
                actual = run(width)
                if actual[0] or b"allowed\n" not in actual[1]:
                    raise RuntimeError("POISON duplicate thread identities did not expose a write")
                checks += 1
            print("  ok    POISON duplicate logical identities", flush=True)

        (tmp / "plain.mere").write_text('let m = map_new (); let _ = map_set m 1 2; print_int (map_get m 1)\n')
        for flag in ("-rvg", "-rv64g"):
            debug = checked([MERE, flag, tmp / "plain.mere"], tmp)
            if b"__map_read" in debug or b"__map_write_" in debug or b"__map_track" in debug:
                raise RuntimeError("Map ownership helpers remain without green threads")
            checks += 1
        expected_checks = len(cases) * 2 + 2 + (18 if args.poison else 0)
        assert checks == expected_checks, "some checks did not run"
        print(f"rv_map_owner: ok ({len(cases)} fixtures at both widths against C; {checks} checks)")


def checked_env(command, cwd, env):
    result = execute(command, cwd, env=env)
    if result.returncode:
        raise RuntimeError(f"{Path(command[0]).name} exited {result.returncode}: " + result.stderr.decode(errors="replace")[:600])
    return result.stdout


def checked(command, cwd):
    return checked_env(command, cwd, None)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.TimeoutExpired, AssertionError, KeyError) as error:
        raise SystemExit(f"rv_map_owner: FAIL {error}")

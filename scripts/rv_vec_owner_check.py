#!/usr/bin/env python3
"""Compare Vec ownership behavior with C, including both RISC-V widths."""
import argparse
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
MERE = Path(os.environ.get("MERE", ROOT / "_build/default/bin/mere.exe")).resolve()
CC = os.environ.get("CC", "cc")
PREFIX = "let launch = fn (f: unit -> unit) -> spawn f;\n"
# These C paths omit a read mark. RV checks the storage they read, including
# an empty loop's length. Pin both results so a C fix makes this list stale.
STRONGER_READS = {
    "read_empty_iter", "read_empty_fold", "read_empty_show", "read_full_show",
    "read_empty_json", "read_full_json", "read_empty_bytes", "read_full_bytes",
    "read_empty_to_owned",
}


def execute(args, cwd, timeout=60, env=None):
    return subprocess.run([str(a) for a in args], cwd=cwd, env=env,
                          capture_output=True, timeout=timeout)


def checked(args, cwd):
    result = execute(args, cwd)
    if result.returncode:
        raise RuntimeError(result.stderr.decode(errors="replace")[:300])
    return result.stdout


def fixtures():
    cases = {}
    writes = {
        "push": ("vec_push v 99", "int"),
        "set": ("vec_set v 0 99", "int"),
        "sort": ("vec_sort v (fn a -> fn b -> a - b)", "int"),
        "recycle": ("vec_recycle v", "int"),
        "compact": ("vec_compact v", "int"),
        "simd": ("f64x2_store v 0 (f64x2_make 8.0 9.0)", "float"),
        "typed_push": ('vec_push v "new"', "str"),
        "typed_set": ('vec_set v 0 "new"', "str"),
    }
    setup = {
        "int": "let _ = vec_push v 2 in vec_push v 1",
        "float": "let _ = vec_push v 2.0 in vec_push v 1.0",
        "str": 'let _ = vec_push v "old" in vec_push v "kept"',
    }
    for op, (expr, kind) in writes.items():
        for seed in ("empty", "full"):
            initial = "()" if seed == "empty" else setup[kind]
            value = {"int": "0", "float": "0.0", "str": '"again"'}[kind]
            common = PREFIX + f"let mk = fn () -> let v = vec_new () in let _ = (if false then vec_push v {value} else ()) in let _ = {initial} in v;\nlet v = mk ();\n"
            catch = f'try_or_msg (fn () -> let _ = {expr} in "allowed") (fn m -> m)'
            cases[f"foreign_{seed}_{op}"] = common + f"""let results = channel_new ();
let h = launch (fn () -> channel_send results ({catch}));
let _ = join h;
let _ = print (channel_recv results);
let _ = print (try_or (fn () -> let _ = vec_push v {value} in "owner-ok") "owner-blocked");
print (show v)
"""
            cases[f"shared_{seed}_{op}"] = common + f"""let h = launch (fn () -> let _ = vec_len v in ());
let _ = join h;
let _ = print ({catch});
print (show v)
"""
    reads = {
        "get": "vec_get v 0", "len": "vec_len v", "generic_len": "len v",
        "to_list": "vec_to_list v", "iter": "vec_iter v (fn x -> ())",
        "fold": "vec_fold v 0 (fn a -> fn x -> a + x)",
        "show": "show v", "json": "to_json v", "bytes": "bytes_of_vec v",
        "to_owned": "vec_to_owned v",
    }
    for op, expr in reads.items():
        for seed in ("empty", "full"):
            if seed == "empty" and op == "get":
                continue
            initial = "()" if seed == "empty" else "vec_push v 1"
            cases[f"read_{seed}_{op}"] = PREFIX + f"""let mk = fn () -> let v = vec_new () in let _ = (if false then vec_push v 1 else ()) in let _ = {initial} in v;
let v = mk ();
let h = launch (fn () -> let _ = {expr} in ());
let _ = join h;
let _ = print (try_or_msg (fn () -> let _ = vec_push v 9 in "allowed") (fn m -> m));
print (show v)
"""
    cases["read_simd"] = PREFIX + """let mk = fn () -> let v = vec_new () in let _ = vec_push v 1.0 in let _ = vec_push v 2.0 in v;
let v = mk ();
let h = launch (fn () -> let _ = f64x2_load v 0 in ());
let _ = join h;
let _ = print (try_or_msg (fn () -> let _ = f64x2_store v 0 (f64x2_make 8.0 9.0) in "allowed") (fn m -> m));
print (show v)
"""
    for ctor, expr in {
        "bytes": 'vec_of_bytes (bytes_of_str "ab")',
        "owned": "let g = owned_vec_new () in let _ = owned_vec_push g 1 in owned_vec_to_vec g",
        "file": 'read_file_bytes "input.bin"',
        "pread": 'let f = file_openrw "input.bin" in let v = file_pread f 0 2 in let _ = file_close f in v',
    }.items():
        cases[f"constructor_{ctor}"] = PREFIX + f"""let v = {expr};
let results = channel_new ();
let h = launch (fn () -> channel_send results (try_or_msg (fn () -> let _ = vec_push v 99 in "allowed") (fn m -> m)));
let _ = join h;
let _ = print (channel_recv results);
print (show v)
"""
    cases["local"] = PREFIX + """let results = channel_new ();
let work = fn () ->
  let v = vec_new () in
  let rec fill = fn (i: int) -> if i == 40 then () else let _ = vec_push v (str_of_int i) in fill (i + 1) in
  let _ = fill 0 in let _ = vec_compact v in
  let _ = vec_set v 0 "kept" in
  let copy = vec_to_list v in
  let _ = vec_recycle v in let _ = vec_push v "again" in
  vec_get v 0 ++ ":" ++ str_of_int (list_len copy);
let h = launch (fn () -> channel_send results (work ()));
let own = work ();
let _ = join h;
print (own ++ ":" ++ channel_recv results)
"""
    cases["nested"] = PREFIX + """let results = channel_new ();
let h = launch (fn () ->
  let v = vec_new () in let _ = vec_push v 1 in
  let child = launch (fn () -> channel_send results (try_or (fn () -> let _ = vec_push v 99 in 0) 7)) in
  let _ = join child in
  let _ = vec_push v 2 in channel_send results (vec_len v));
let _ = join h;
print_int (channel_recv results + channel_recv results)
"""
    cases["par_map"] = """let mk = fn () -> let v = vec_new () in let _ = vec_push v 1 in v;
let v = mk ();
let run = fn (f: int -> int) -> par_map f [1, 2];
let xs = run (fn x -> let _ = vec_get v 0 in x + 1);
let write = try_or (fn () -> let _ = vec_push v 9 in 0) 7;
let h = spawn (fn () -> let own = vec_new () in let _ = vec_push own 4 in print_int (vec_get own 0));
let _ = join h;
print_int (list_sum xs + write)
"""
    cases["par_map_caught"] = """let mk = fn () -> let v = vec_new () in let _ = vec_push v 1 in v;
let v = mk ();
let run = fn (f: int -> int) -> par_map f [1];
let xs = run (fn x -> try_or (fn () -> let _ = vec_push v 9 in 0) 7);
let _ = vec_push v 2;
print_int (list_sum xs + vec_len v)
"""
    cases["identities"] = PREFIX + """let callbacks = channel_new ();
let ready = channel_new ();
let results = channel_new ();
let a = launch (fn () ->
  let v = vec_new () in let _ = vec_push v 1 in
  let _ = channel_send callbacks (fn () -> vec_len v) in
  let _ = channel_recv ready in
  channel_send results (try_or (fn () -> let _ = vec_push v 2 in 0) 7));
let b = launch (fn () -> let read = channel_recv callbacks in let _ = read () in channel_send ready ());
let _ = join a;
let _ = join b;
print_int (channel_recv results)
"""
    for name in ("param_vec", "param_versioned", "shared_versioned", "shared_vec_phase", "vec_caught", "vec_recycle_caught", "shared_vec_recycle"):
        cases[name] = (ROOT / "test/owner" / f"{name}.mere").read_text()
    cases["retrack_foreign"] = cases["foreign_full_push"].replace(
        "channel_send results (try_or_msg", "let _ = __rv_vec_track v in channel_send results (try_or_msg")
    cases["retrack_shared"] = cases["read_full_len"].replace(
        "let _ = print (try_or_msg", "let _ = __rv_vec_track v;\nlet _ = print (try_or_msg")
    return cases


def guest(result):
    def strip(data):
        return b"".join(line for line in data.splitlines(keepends=True)
                        if not line.startswith(b"rvrun"))
    return result.returncode, strip(result.stdout), strip(result.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--poison", action="store_true")
    args = parser.parse_args()
    memu = Path(os.environ.get("MEMU", ""))
    if not (memu / "riscv-runc/rv32i_run.mere").is_file():
        parser.error("set MEMU to a memu checkout; both widths must run")
    with tempfile.TemporaryDirectory(prefix="rv-vec-owner-") as directory:
        tmp = Path(directory)
        runners = {}
        for width in (32, 64):
            source = checked([MERE, "-c", memu / f"riscv-runc/rv{width}i_run.mere"], tmp)
            (tmp / "runner.c").write_bytes(source)
            runners[width] = tmp / f"rvrun{width}"
            checked([CC, "-O2", "-w", "runner.c", "-o", runners[width], "-lm"], tmp)
        cases = fixtures()
        assert len(cases) == 70, "fixture catalogue changed"
        (tmp / "input.bin").write_bytes(b"ab")
        references = {}
        checks = 0
        failures = []

        def build(name, width, env=None):
            flag = "-rv" if width == 32 else "-rv64"
            result = execute([MERE, flag, "--ram", "32", tmp / f"{name}.mere"], tmp, env=env)
            if result.returncode:
                raise RuntimeError(result.stderr.decode(errors="replace")[:300])
            (tmp / "prog.bin").write_bytes(result.stdout)

        def run(width):
            return guest(execute([runners[width], "32"], tmp))

        for name, source in cases.items():
            (tmp / f"{name}.mere").write_text(source)
            # Attaching metadata to an already tracked Vec must be an identity.
            # C has no such internal intrinsic, so its reference omits that call.
            reference_source = source
            if name.startswith("retrack_"):
                assert source.count("__rv_vec_track v") == 1
                reference_source = source.replace("__rv_vec_track v", "v")
            (tmp / "reference.mere").write_text(reference_source)
            (tmp / "ref.c").write_bytes(checked([MERE, "-c", tmp / "reference.mere"], tmp))
            checked([CC, "-O1", "-w", "ref.c", "-o", "ref", "-lm", "-lpthread"], tmp)
            result = execute([tmp / "ref"], tmp)
            references[name] = (result.returncode, result.stdout, result.stderr)
            expected = references[name]
            if name in STRONGER_READS:
                seed = name.split("_")[1]
                native_contents = b"Vec[9]\n" if seed == "empty" else b"Vec[1, 9]\n"
                if expected != (0, b"allowed\n" + native_contents, b""):
                    raise RuntimeError(f"{name}: C's unmarked-read entry is stale")
                expected = references[f"read_{seed}_len"]
            for width in (32, 64):
                build(name, width)
                actual = run(width)
                if actual != expected:
                    failures.append(f"{name}: RV{width} differs from expected read/write behavior: {actual!r} versus {expected!r}")
                    print("  FAIL  " + failures[-1], flush=True)
                checks += 1
            if name not in [message.split(":")[0] for message in failures]:
                behavior = "pin the stricter read mark" if name in STRONGER_READS else "match C"
                print(f"  ok    {name}: RV32 and RV64 {behavior}", flush=True)

        if failures:
            raise RuntimeError(f"{len(failures)} comparisons differed from C")

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
                assert data[offset:offset + 4] != struct.pack("<I", 0x8067)
                data[offset:offset + 4] = struct.pack("<I", 0x8067)
            (tmp / "prog.bin").write_bytes(data)

        if args.poison:
            poisons = [
                ("foreign_full_push", ["__vec_write_vec_push"]),
                ("foreign_full_set", ["__vec_write_vec_set"]),
                ("foreign_empty_sort", ["__vec_write_vec_sort"]),
                ("foreign_full_recycle", ["__vec_write_vec_recycle"]),
                ("foreign_full_compact", ["__vec_write_vec_compact"]),
                ("foreign_full_simd", ["__vec_write_f64x2_store", "__vec_write_vec_set"]),
                ("read_full_len", ["__vec_read"]),
                ("foreign_full_push", ["__vec_track"]),
                ("constructor_bytes", ["__vec_track"]),
                ("constructor_owned", ["__vec_track"]),
                ("constructor_file", ["__vec_track"]),
                ("constructor_pread", ["__vec_track"]),
            ]
            for name, labels in poisons:
                for width in (32, 64):
                    remove_helper(name, width, labels)
                    actual = run(width)
                    if actual[0] != 0 or b"allowed\n" not in actual[1] or actual == references[name]:
                        raise RuntimeError(f"POISON {name}: RV{width} did not expose an allowed write: {actual!r}")
                    checks += 1
                print(f"  ok    POISON {name}: removed {', '.join(labels)}", flush=True)
            prelude = checked([MERE, "--rv-prelude"], tmp).decode()
            poisoned = prelude.replace("__rv_rtw_set 81 next", "__rv_rtw_set 81 0")
            assert poisoned != prelude
            (tmp / "prelude.mere").write_text(poisoned)
            env = dict(os.environ, MERE_RV_PRELUDE_FILE=str(tmp / "prelude.mere"))
            for width in (32, 64):
                build("foreign_full_push", width, env)
                actual = run(width)
                if actual[0] != 0 or b"allowed\n" not in actual[1]:
                    raise RuntimeError("POISON duplicate thread identities did not expose an allowed write")
                checks += 1
            print("  ok    POISON duplicate logical identities", flush=True)

        (tmp / "plain.mere").write_text('let v = vec_new (); let _ = vec_push v 1; print_int (vec_get v 0)\n')
        for flag in ("-rvg", "-rv64g"):
            debug = checked([MERE, flag, tmp / "plain.mere"], tmp)
            if b"__vec_read" in debug or b"__vec_write_" in debug or b"__vec_track" in debug:
                raise RuntimeError("ownership helpers remain in a program without green threads")
            checks += 1
        assert checks == (168 if args.poison else 142), "some checks did not run"
        print(f"rv_vec_owner: ok ({len(cases)} fixtures at both widths, including {len(STRONGER_READS)} stricter read paths; {checks} checks)")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.TimeoutExpired, AssertionError, KeyError) as error:
        raise SystemExit(f"rv_vec_owner: FAIL {error}")

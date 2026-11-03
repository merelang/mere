#!/usr/bin/env python3
"""Vec formatting and empty traversals must freeze foreign reads on C."""
import argparse
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
MERE = Path(os.environ.get("MERE", ROOT / "_build/default/bin/mere.exe")).resolve()
CC = os.environ.get("CC", "cc")
spec = importlib.util.spec_from_file_location("rv_owner", ROOT / "scripts/rv_vec_owner_check.py")
rv_owner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rv_owner)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--poison", action="store_true")
    args = parser.parse_args()
    cases = {
        "read_empty_iter": "iter", "read_empty_fold": "fold",
        "read_empty_show": "show", "read_full_show": "show",
        "read_empty_json": "json", "read_full_json": "json",
        "read_empty_bytes": "bytes", "read_full_bytes": "bytes",
        "read_empty_to_owned": "to-owned",
    }
    checks = 0
    with tempfile.TemporaryDirectory(prefix="c-vec-read-") as directory:
        tmp = Path(directory)

        def run(command):
            return subprocess.run([str(x) for x in command], cwd=tmp,
                                  capture_output=True, timeout=60)

        def compile_c(source):
            (tmp / "case.mere").write_text(source)
            emitted = run([MERE, "-c", tmp / "case.mere"])
            if emitted.returncode:
                raise RuntimeError(emitted.stderr.decode(errors="replace")[:300])
            return emitted.stdout.decode()

        def execute(code):
            (tmp / "case.c").write_text(code)
            built = run([CC, "-O2", "-w", "case.c", "-o", "case", "-lm", "-lpthread"])
            if built.returncode:
                raise RuntimeError(built.stderr.decode(errors="replace")[:300])
            result = run([tmp / "case"])
            if result.returncode or result.stderr:
                raise RuntimeError(f"unexpected C failure: {result.returncode}, {result.stderr[:200]!r}")
            return result.stdout

        fixtures = rv_owner.fixtures()
        message = (b"vec_push: a Vec another thread has read was written -- once a second thread reads a Vec "
                   b"it is shared, and a shared Vec is read-only; give it one owner thread and send it messages over a Channel\n")
        for name, mark in cases.items():
            code = compile_c(fixtures[name])
            empty = "empty" in name
            expected = message + (b"Vec[]\n" if empty else b"Vec[1]\n")
            if execute(code) != expected:
                raise RuntimeError(f"{name}: source Vec remained writable or contents changed")
            checks += 1
            print(f"  ok    C {name}", flush=True)
            if args.poison:
                variable = "__vc" if mark in {"iter", "fold", "to-owned"} else "v"
                text = f"__LANG_READ({variable}); /* vec-{mark}-read */"
                if code.count(text) != 1:
                    raise RuntimeError(f"{name}: expected one read mark")
                expected = b"allowed\n" + (b"Vec[9]\n" if empty else b"Vec[1, 9]\n")
                if execute(code.replace(text, "")) != expected:
                    raise RuntimeError(f"POISON {name}: removing its read mark did not allow mutation")
                checks += 1
                print(f"  ok    POISON C {name}: source write succeeds", flush=True)

        for op, (expression, read, expected) in {
            "list": ("vec_to_list v", "list_sum snapshot", 3),
            "bytes": ("bytes_of_vec v", "bytes_len snapshot", 3),
            "json": ("to_json v", "str_len snapshot", 5),
        }.items():
            source = f"""let v = vec_new ();
let _ = vec_push v 1;
let snapshot = {expression};
let results = channel_new ();
let h = spawn (fn () -> channel_send results ({read}));
let _ = join h;
let _ = vec_push v 2;
print_int (vec_len v + channel_recv results)
"""
            if execute(compile_c(source)) != f"{expected}\n".encode():
                raise RuntimeError(f"immutable {op} snapshot froze its source")
            checks += 1
            print(f"  ok    C immutable {op} snapshot", flush=True)

        json_cases = {
            "empty": 'let v = (vec_new () : int Vec); print (to_json v)\n',
            "int": 'let v = vec_new (); let _ = vec_push v 1; print (to_json v)\n',
            "nested": '''type Row = { cells: str Vec };
let v = vec_new ();
let _ = vec_push v "a\\\"b";
let _ = vec_push v "line\\nnext";
let empty = (vec_new () : int Vec);
print (to_json (Row { cells = v }, empty))
''',
            "growth": '''let v = vec_new ();
let rec fill = fn (i: int) -> if i == 512 then () else let _ = vec_push v (str_of_int i) in fill (i + 1);
let _ = fill 0;
print (to_json v)
''',
        }
        for name, source in json_cases.items():
            code = compile_c(source)
            expected = run([MERE, tmp / "case.mere"])
            if expected.returncode or expected.stderr or execute(code) != expected.stdout:
                raise RuntimeError(f"Vec JSON {name} differs from the interpreter")
            checks += 1
            print(f"  ok    C Vec JSON {name}", flush=True)
        expected_checks = 25 if args.poison else 16
        if checks != expected_checks:
            raise RuntimeError(f"expected {expected_checks} checks, ran {checks}")
        print(f"c_vec_read: ok ({checks} checks)")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        raise SystemExit(f"c_vec_read: FAIL {error}")

#!/usr/bin/env python3
"""Require invalid resource closes to fail in the checker and every backend."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
MERE = Path(os.environ.get("MERE", ROOT / "_build/default/bin/mere.exe"))
CASES = {
    "value": "drop type C = { close: int }; with r = C { close = 1 } in 42",
    "argument": "drop type C = { close: int -> unit }; with r = C { close = print_int } in 42",
    "result": "drop type C = { close: unit -> int }; with r = C { close = fn () -> 1 } in 42",
    "curried": "drop type C = { close: unit -> unit -> unit }; with r = C { close = fn () -> fn () -> () } in 42",
    "generic_value": "drop type 'a C = { close: 'a }; with r = C { close = 1 } in 42",
    "generic_argument": "drop type 'a C = { close: 'a -> unit }; with r = C { close = print_int } in 42",
    "generic_result": "drop type 'a C = { close: unit -> 'a }; with r = C { close = fn () -> 1 } in 42",
}

def main():
    checked = 0
    with tempfile.TemporaryDirectory(prefix="with-close-check-") as directory:
        case = Path(directory) / "bad.mere"
        for name, source in CASES.items():
            case.write_text(source + "\n")
            for flag in [None, "check", "-c", "-ll", "-w", "-rv", "-rv64"]:
                args = [MERE, case] if flag is None else [MERE, flag, case]
                result = subprocess.run(args, capture_output=True, timeout=30)
                assert result.returncode and b"close must have type unit -> unit" in result.stderr, (name, flag, result.stderr[:500])
                checked += 1
        case.write_text("drop type 'a C = { close: 'a }; let use = fn (r: 'a C) -> with x = r in 42; use (C { close = 1 })\n")
        for flag in [None, "check", "-c", "-ll", "-w", "-rv", "-rv64"]:
            args = [MERE, case] if flag is None else [MERE, flag, case]
            result = subprocess.run(args, capture_output=True, timeout=30)
            assert result.returncode and b"type error" in result.stderr, (flag, result.stderr[:500])
            checked += 1
    print(f"with_close: {checked} refusal checks passed across interpreter, checker and all compiled targets")

if __name__ == "__main__":
    main()

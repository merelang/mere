#!/usr/bin/env python3
"""Check snapshot lifetimes, the necessity of copying, and plain-value bounds."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
MERE = Path(os.environ.get("MERE", ROOT / "_build/default/bin/mere.exe"))
EXPECTED = b"before 6\n610062\nonce\n1\noutside\n30\n70\n50\nopt 7\n42\n43\n"
NEGATIVE = {
    "vec": "snapshot (vec_new ())",
    "tuple": "snapshot (1, vec_new ())",
    "wrapper": "let f = fn x -> snapshot x; f (vec_new ())",
    "alias": "let f = snapshot; f (vec_new ())",
    "record": "type Box = { v: Vec[__heap, int] }; let v = vec_new (); let _ = vec_push v 1; snapshot (Box { v = v })",
    "variant": "type Box = Empty | Full of Vec[__heap, int]; snapshot Empty",
    "nested_recursive": "type 'a Nest = End of 'a | More of Vec[__heap, 'a] Nest; let f = fn (v: int Nest) -> snapshot v; 0",
    "function": "snapshot (fn x -> x)",
    "borrow": "region R { let b = snapshot (&R 1) in () }",
    "file": "let f = fn (v: File) -> snapshot v; 0",
    "opaque": "extern type Handle; let f = fn (v: Handle) -> snapshot v; 0",
    "forward_wrapper": "let fn snap: 'a -> 'a; let snap = fn x -> snapshot x; snap (vec_new ())",
}


def run(args, directory, check=True):
    r = subprocess.run([str(a) for a in args], cwd=directory, capture_output=True, timeout=60)
    if check and (r.returncode or r.stderr):
        raise RuntimeError(f"{Path(str(args[0])).name} failed: {r.stderr.decode(errors='replace')[:1000]}")
    return r


def main():
    with tempfile.TemporaryDirectory(prefix="snapshot-check-") as d:
        tmp = Path(d)
        source = (ROOT / "test/parity/snapshot.mere").read_text()
        case = tmp / "probe.mere"
        case.write_text(source)
        code = run([MERE, "-c", case], tmp).stdout
        (tmp / "probe.c").write_bytes(code)
        for optimization in ["-O0", "-O2"]:
            run(["clang", optimization, "-w", "-fsanitize=address,undefined", "-fno-sanitize-recover=all",
                 "probe.c", "-o", "probe", "-lm", "-lpthread"], tmp)
            assert run([tmp / "probe"], tmp).stdout == EXPECTED
        marker = 'snapshot (map_get m "k")'
        assert source.count(marker) == 1
        case.write_text(source.replace(marker, '(map_get m "k")'))
        (tmp / "probe.c").write_bytes(run([MERE, "-c", case], tmp).stdout)
        run(["clang", "-O2", "-w", "-fsanitize=address,undefined", "probe.c", "-o", "probe", "-lm", "-lpthread"], tmp)
        poisoned = run([tmp / "probe"], tmp, check=False)
        assert poisoned.returncode and b"heap-use-after-free" in poisoned.stderr
        print("snapshot: O0/O2 ASan/UBSan passed; removing the copy exposes heap-use-after-free", flush=True)
        checks = 0
        for name, text in NEGATIVE.items():
            case.write_text(text + "\n")
            for flag in [None, "check", "-c", "-ll", "-w", "-rv", "-rv64"]:
                args = [MERE, case] if flag is None else [MERE, flag, case]
                r = run(args, tmp, check=False)
                assert r.returncode and b"snapshot cannot copy" in r.stderr, (name, flag, r.stderr[:500])
                checks += 1
        print(f"snapshot: {checks} plain-value refusal checks passed", flush=True)


if __name__ == "__main__":
    main()

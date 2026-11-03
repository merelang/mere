#!/usr/bin/env python3
"""OwnedVec conversion must check and claim its source, even when empty."""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile

from rv_builder_owner_check import checked
from rv_ownedvec_owner_check import fixtures
from rv_vec_owner_check import execute, MERE, CC, ROOT


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--poison", action="store_true")
    args = parser.parse_args()
    for tool in ("clang", "wat2wasm", "node"):
        if not shutil.which(tool):
            raise RuntimeError(f"required tool missing: {tool}")
    cases = {k: v for k, v in fixtures().items() if
             (k.startswith("foreign_") and k.endswith("_to_vec")) or
             (k.startswith("after_move_") and k.endswith("_to_vec")) or
             k.startswith("conversion_claim_") or k in {"local_move"}}
    assert len(cases) == 11
    checks = 0
    with tempfile.TemporaryDirectory(prefix="ownedvec-conversion-") as directory:
        tmp = Path(directory)
        def run_native(code, backend):
            suffix = "c" if backend == "C" else "ll"
            (tmp / ("case." + suffix)).write_bytes(code)
            compiler = CC if backend == "C" else "clang"
            checked([compiler, "-O2", "-w", "case." + suffix, "-o", "case", "-lm", "-lpthread"], tmp)
            result = execute([tmp / "case"], tmp)
            return result.returncode, result.stdout, result.stderr
        for name, source in cases.items():
            if name.startswith("foreign_"):
                # Hide the OwnedVec behind a function alias so every backend
                # sees an opaque callback rather than a direct move capture.
                source = source.replace('let _ = owned_vec_to_vec g in "allowed"',
                                        'let _ = convert () in "allowed"')
                source = source.replace('let results = channel_new ();',
                                        'let convert = fn () -> owned_vec_to_vec g;\nlet results = channel_new ();')
            file = tmp / "case.mere"
            file.write_text(source)
            c = checked([MERE, "-c", file], tmp)
            ref = run_native(c, "C")
            if ref[0] or ref[2] or b"allowed\n" in ref[1]:
                raise RuntimeError(f"{name}: C allowed conversion or failed unexpectedly: {ref!r}")
            checks += 1
            interp = execute([MERE, file], tmp)
            if (interp.returncode, interp.stdout, interp.stderr) != ref:
                raise RuntimeError(f"{name}: interpreter differs from C: {interp.stdout!r} {interp.stderr!r}")
            checks += 1
            llvm = checked([MERE, "-ll", file], tmp)
            if run_native(llvm, "LLVM") != ref:
                raise RuntimeError(f"{name}: LLVM differs from C")
            checks += 1
            wat = checked([MERE, "-w", file], tmp)
            (tmp / "module.wat").write_bytes(wat)
            checked(["wat2wasm", "--enable-tail-call", "--enable-threads", "module.wat", "-o", "module.wasm"], tmp)
            wasm = execute(["node", ROOT / "scripts/run_wasm.js", tmp / "module.wasm"], tmp)
            if (wasm.returncode, wasm.stdout, wasm.stderr) != ref:
                raise RuntimeError(f"{name}: Wasm differs from C: {wasm.stdout!r} {wasm.stderr!r}")
            checks += 1
            print(f"  ok    {name}: interpreter, C, LLVM and Wasm", flush=True)
            if args.poison and name in {"foreign_new_empty_to_vec", "foreign_copy_empty_to_vec"}:
                marks = {
                    "C": (c, b'__lang_ov_use(&__ov->owner, "owned_vec_to_vec"); /* ov-to-vec-owner */'),
                    "LLVM": (llvm, b'call void @__lang_ov_use(ptr %__ov_p, ptr @.ov_owned_vec_to_vec) ; ov-to-vec-owner'),
                }
                for backend, (code, mark) in marks.items():
                    if not code.count(mark):
                        raise RuntimeError(f"{backend}: conversion ownership marker is missing")
                    actual = run_native(code.replace(mark, b""), backend)
                    if actual[0] or b"allowed\n" not in actual[1] or actual == ref:
                        raise RuntimeError(f"POISON {name}: {backend} did not expose the missing conversion guard")
                    checks += 1
                    print(f"  ok    POISON {name}: {backend}", flush=True)
        assert checks == (48 if args.poison else 44)
        print(f"ownedvec_conversion: ok ({checks} checks)")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.TimeoutExpired, AssertionError) as error:
        raise SystemExit(f"ownedvec_conversion: FAIL {error}")

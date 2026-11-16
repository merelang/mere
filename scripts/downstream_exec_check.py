#!/usr/bin/env python3
"""Link and execute two downstreams through C and LLVM against explicit answers."""
import argparse
from dataclasses import dataclass
import hashlib
import math
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parent.parent
BACKENDS = ("c", "ll")
ENTRIES = {"mwasm": "main.mere", "mbigfmt": "bigfmt.mere"}
EXPECTED_CASES = {"mwasm": ("bare", "exports", "custom", "short", "bad-magic"),
                  "mbigfmt": ("format-and-arithmetic",)}


class Failure(Exception):
    def __init__(self, stage, label, detail):
        self.stage = stage
        super().__init__(f"{label}: {stage}: {detail}")


@dataclass(frozen=True)
class Case:
    name: str
    args: tuple = ()
    stdout: bytes = b""
    stderr: bytes = b""
    status: int = 0


def execute(command, cwd, label, stage, seconds):
    """Each invocation owns a process group, including compiler subprocesses."""
    try:
        child = subprocess.Popen(command, cwd=cwd, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, start_new_session=True)
    except OSError as error:
        raise Failure(stage, label, str(error)) from error
    try:
        try:
            stdout, stderr = child.communicate(timeout=seconds)
        except subprocess.TimeoutExpired as error:
            raise Failure(stage + " timeout", label, f"exceeded {seconds}s") from error
        return subprocess.CompletedProcess(command, child.returncode, stdout, stderr)
    finally:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.communicate()


def checked(command, cwd, label, stage, seconds=120):
    result = execute(command, cwd, label, stage, seconds)
    if result.returncode:
        diagnostic = result.stderr.decode(errors="replace")[:500]
        raise Failure(stage, label, f"exit {result.returncode}: {diagnostic}")
    return result


def link(code, backend, compiler, work, label):
    source = work / ("program.c" if backend == "c" else "program.ll")
    source.write_bytes(code)
    obj = work / "program.o"
    binary = work / "program"
    checked([*compiler, "-O2", "-w", "-pthread", "-c", str(source), "-o", str(obj)],
            work, label, "compile")
    checked([*compiler, str(obj), "-o", str(binary), "-lm", "-pthread"],
            work, label, "link")
    return binary


def build(mere, source, backend, compiler, work, label):
    emitted = checked([mere, "-" + backend, str(source)], source.parent, label, "emit")
    if not emitted.stdout:
        raise Failure("emit", label, "no generated code")
    return link(emitted.stdout, backend, compiler, work, label)


def compare(binary, case, cwd, label, seconds=10):
    result = execute([str(binary), *case.args], cwd, label, "run", seconds)
    if result.returncode < 0:
        raise Failure("signal", label, f"signal {-result.returncode}")
    if result.returncode != case.status:
        raise Failure("exit", label, f"wanted {case.status}, got {result.returncode}")
    for stream in ("stdout", "stderr"):
        actual, wanted = getattr(result, stream), getattr(case, stream)
        if actual != wanted:
            raise Failure(stream, label, f"wanted {wanted[:180]!r}, got {actual[:180]!r}")


def mwasm_cases(work):
    header = b"\x00asm\x01\x00\x00\x00"
    # (module (func (export "run") (result i32) i32.const 42)
    #         (memory (export "mem") 1))
    exports = header + bytes.fromhex(
        "01 05 01 60 00 01 7f 03 02 01 00 05 03 01 00 01 "
        "07 0d 02 03 72 75 6e 00 00 03 6d 65 6d 02 00 0a 06 01 04 00 41 2a 0b")
    inputs = {"bare.wasm": header, "exports.wasm": exports,
              "custom.wasm": header + b"\x00\x81\x01\x04note" + bytes(124),
              "short.wasm": header[:4], "bad.wasm": b"bad!" + header[4:]}
    for name, data in inputs.items():
        (work / name).write_bytes(data)
    return [
        Case("bare", ("bare.wasm",), b"wasm module: bare.wasm (8 bytes, version 1)\n"),
        Case("exports", ("exports.wasm",),
             b"wasm module: exports.wasm (47 bytes, version 1)\n"
             b"  section 1 (type): 5 bytes\n  section 3 (function): 2 bytes\n"
             b"  section 5 (memory): 3 bytes\n  section 7 (export): 13 bytes\n"
             b"    exports (2):\n      func run -> 0\n      memory mem -> 0\n"
             b"  section 10 (code): 6 bytes\n"),
        Case("custom", ("custom.wasm",),
             b"wasm module: custom.wasm (140 bytes, version 1)\n  section 0 (custom): 129 bytes\n"),
        Case("short", ("short.wasm",), stderr=b"mwasm: file too small to be wasm\n", status=1),
        Case("bad-magic", ("bad.wasm",), stderr=b"mwasm: not a wasm file (bad magic)\n", status=1),
    ]


def bigfmt_case():
    # Arithmetic is evaluated by Python, independently of the downstream's
    # big-natural representation and its formatting algorithm.
    fib0, fib1 = 0, 1
    for _ in range(200):
        fib0, fib1 = fib1, fib0 + fib1
    lines = ["", "0", "12", "123", "1,234", "001,234", "1,234,567", ",".join(["123"] * 400)]
    lines += [f"{math.factorial(n):,}" for n in (0, 1, 30, 100)]
    lines += ["0", "1", f"{fib0:,}"]
    return Case("format-and-arithmetic", stdout=("\n".join(lines) + "\n").encode())


def expected_executions():
    return {(repo, backend, name) for repo, names in EXPECTED_CASES.items()
            for backend in ("c", "ll") for name in names}


def check_coverage(executed):
    required = expected_executions()
    if set(executed) != required or len(executed) != len(required):
        raise Failure("coverage", "downstream_exec", "every required case must execute exactly once on C and LLVM")


def sources(directory, work):
    prepared = {}
    for repo, entry in ENTRIES.items():
        original = directory / repo / entry
        if not original.is_file():
            raise Failure("setup", repo, f"required entry missing: {entry}")
        project = work / repo
        project.mkdir()
        source = project / "entry.mere"
        contents = original.read_bytes()
        print(f"downstream_exec: {repo} source SHA-256 {hashlib.sha256(contents).hexdigest()}", flush=True)
        if repo == "mbigfmt":
            modules = directory / repo / ".mere_modules"
            if not modules.is_dir():
                raise Failure("setup", repo, "dependencies missing; run mere install in the checkout")
            (project / ".mere_modules").symlink_to(modules, target_is_directory=True)
            shutil.copyfile(original.parent / "mere.toml", project / "mere.toml")
            contents += b"\n" + (ROOT / "test/downstream/mbigfmt_exec.mere").read_bytes()
        source.write_bytes(contents)
        prepared[repo] = source
    return prepared


def poison_checks(mere, compiler, prepared, cases, inputs, work, directory):
    count = 0

    def expect(stage, label, action):
        nonlocal count
        try:
            action()
        except Failure as error:
            if error.stage != stage:
                raise Failure("control", label, f"wanted {stage}, got {error}") from error
            count += 1
            print(f"downstream_exec: poison caught {label} ({stage})", flush=True)
            return
        raise Failure("control", label, "incorrect program was accepted")

    expected = sorted(expected_executions())
    for label, executed in (("no executions", []), ("missing LLVM", [item for item in expected if item[1] == "c"]),
                            ("duplicated execution", expected + expected[:1])):
        expect("coverage", label, lambda: check_coverage(executed))

    for absent in ENTRIES:
        checkout = work / ("missing-" + absent)
        checkout.mkdir()
        for repo in ENTRIES:
            if repo != absent:
                (checkout / repo).symlink_to(directory / repo, target_is_directory=True)
        scratch = work / ("missing-work-" + absent)
        scratch.mkdir()
        expect("setup", "missing " + absent, lambda: sources(checkout, scratch))

    invalid = work / "invalid.mere"
    invalid.write_text("let =\n")
    for backend in BACKENDS:
        scratch = work / ("bad-emit-" + backend)
        scratch.mkdir()
        expect("emit", backend + " emission failure",
               lambda: build(mere, invalid, backend, compiler, scratch, "invalid source"))
        scratch = work / ("bad-compile-" + backend)
        scratch.mkdir()
        code = b"#error intentional\n" if backend == "c" else b"invalid LLVM\n"
        expect("compile", backend + " compilation failure",
               lambda: link(code, backend, compiler, scratch, "invalid generated code"))
        scratch = work / ("bad-link-" + backend)
        scratch.mkdir()
        code = (b"extern int downstream_missing(void); int main(void) { return downstream_missing(); }\n"
                if backend == "c" else
                b"declare i32 @downstream_missing()\ndefine i32 @main() {\n"
                b"%r = call i32 @downstream_missing()\nret i32 %r\n}\n")
        # Both objects compile successfully; only the executable link fails.
        expect("link", backend + " unresolved symbol",
               lambda: link(code, backend, compiler, scratch, "missing symbol"))

    for repo, source in prepared.items():
        before, after = ((b'else if id == 1 then "type"', b'else if id == 1 then "wrong"')
                         if repo == "mwasm" else (b"Bigfmt.fact 100", b"Bigfmt.fact 99"))
        contents = source.read_bytes()
        if contents.count(before) != 1:
            raise Failure("control", repo, "downstream behavior mutation no longer matches once")
        mutant = source.with_name("mutated.mere")
        mutant.write_bytes(contents.replace(before, after))
        case = cases[repo][1] if repo == "mwasm" else cases[repo][0]
        for backend in BACKENDS:
            label = repo + "/" + backend + " changed behavior"
            scratch = work / ("mutated-" + repo + "-" + backend)
            scratch.mkdir()
            binary = build(mere, mutant, backend, compiler, scratch, label)
            expect("stdout", label, lambda: compare(binary, case, inputs, label))

    scratch = work / "native-controls"
    scratch.mkdir()
    binary = link((ROOT / "test/downstream/exec_control.c").read_bytes(), "c", compiler, scratch, "runner controls")
    compare(binary, Case("baseline", ("ok",), b"ok\n"), inputs, "runner baseline")
    for mode, stage in (("wrong", "stdout"), ("extra", "stdout"), ("silent", "stdout"),
                        ("stderr", "stderr"), ("exit", "exit"), ("signal", "signal")):
        case = Case(mode, (mode,), b"ok\n")
        expect(stage, "runner " + mode, lambda: compare(binary, case, inputs, mode))
    expect("run timeout", "hung program", lambda: compare(binary, Case("hang", ("hang",)), inputs, "hang", 0.1))
    marker = inputs / "descendant-survived"
    ready = inputs / "descendant-ready"
    case = Case("descendant", ("descendant", str(marker), str(ready)))
    expect("run timeout", "hung process family", lambda: compare(binary, case, inputs, "descendant", 0.3))
    if not ready.exists():
        raise Failure("control", "process family", "descendant did not start before the deadline")
    time.sleep(1.1)
    if marker.exists():
        raise Failure("control", "process family", "timeout left a descendant running")
    if count != 23:
        raise Failure("coverage", "poison controls", f"wanted 23, got {count}")
    print(f"downstream_exec: {count} poison controls passed; timed-out descendants cleaned up", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--poison", action="store_true", help="also prove emission, compile, link and execution failures are rejected")
    args = parser.parse_args()
    directory = os.environ.get("MERE_DOWNSTREAM")
    if not directory:
        raise Failure("setup", "downstream_exec", "MERE_DOWNSTREAM is required; no checkouts checked")
    mere = shutil.which(os.environ.get("MERE", str(ROOT / "_build/default/bin/mere.exe")))
    compiler = shlex.split(os.environ.get("CC", "clang"))
    if not mere or not compiler or not shutil.which(compiler[0]):
        raise Failure("setup", "downstream_exec", "Mere and a clang-compatible compiler are required")
    with tempfile.TemporaryDirectory(prefix="mere-downstream-exec-") as temp:
        work = Path(temp)
        prepared = sources(Path(directory).resolve(), work)
        inputs = work / "inputs"
        inputs.mkdir()
        cases = {"mwasm": mwasm_cases(inputs), "mbigfmt": [bigfmt_case()]}
        executed = []
        for repo, source in prepared.items():
            for backend in BACKENDS:
                build_dir = work / (repo + "-" + backend)
                build_dir.mkdir()
                label = repo + "/" + backend
                binary = build(mere, source, backend, compiler, build_dir, label)
                for case in cases[repo]:
                    compare(binary, case, inputs, label + "/" + case.name)
                    executed.append((repo, backend, case.name))
                print(f"downstream_exec: {label} {len(cases[repo])} cases passed", flush=True)
        check_coverage(executed)
        print(f"downstream_exec: {len(executed)} executions passed (C and LLVM, exact status/stdout/stderr)")
        if args.poison:
            poison_checks(mere, compiler, prepared, cases, inputs, work, Path(directory).resolve())


def terminate(signum, _frame):
    raise SystemExit(128 + signum)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, terminate)
    try:
        main()
    except Failure as error:
        print(f"FAIL downstream_exec: {error}", file=sys.stderr, flush=True)
        raise SystemExit(1)

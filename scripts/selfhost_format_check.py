#!/usr/bin/env python3
"""Check exact formatting, raw declarations and executable extern signatures."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ["t06_patterns", "t07_pattern_visibility", "t08_logic", "t09_records",
            "t10_aliases", "t11_polymorphic_types", "t12_type_modules", "t13_type_scope",
            "t14_annotations", "t15_constructors", "t16_constructor_scope"]


def run(args):
    result = subprocess.run([str(arg) for arg in args], cwd=ROOT, capture_output=True, timeout=180)
    assert result.returncode == 0, (args, result.returncode, result.stderr[-2000:])
    return result.stdout


def check(mere, compiler, output):
    output.mkdir(parents=True, exist_ok=True)
    work = output / "checks"
    work.mkdir(exist_ok=True)
    driver = ROOT / "test/selfhost/format_driver.mere"
    wat = work / "formatter.wat"
    wasm = wat.with_suffix(".wasm")
    wat.write_bytes(run([mere, "-w", driver]))
    run(["wat2wasm", "--enable-tail-call", wat, "-o", wasm])

    def apply(mode, source, target, compiled=False):
        if target.exists():
            target.unlink()
        prefix = ["node", ROOT / "scripts/run_wasm.js", wasm] if compiled else [mere, driver]
        assert run([*prefix, mode, source, target]) == b"", "formatter driver must write exact files"
        return target.read_bytes()

    def roundtrip(name, source, expected=None):
        target = output / (name + ".mere")
        formatted = apply("format", source, target)
        if expected is not None:
            assert formatted == expected, (name, formatted, expected)
        assert apply("format", source, work / "wasm.mere", True) == formatted, name
        for compiled in [False, True]:
            assert apply("format", target, work / "again.mere", compiled) == formatted, name
        original = apply("ast", source, work / "original.ast")
        assert apply("ast", target, work / "formatted.ast", True) == original, name
        return target

    rows = [line.split("\t") for line in
            (ROOT / "test/selfhost/format_declarations.tsv").read_text().splitlines()]
    assert len(rows) == 12 and all(len(row) == 3 for row in rows)
    assert len({row[0] for row in rows}) == 12
    for name, expected, source in rows:
        path = work / (name + ".mere")
        path.write_text(source + "\n")
        roundtrip("layout-" + name, path, json.loads(expected).encode())
    print("  formatter declarations: 12 handwritten layouts, interpreter/Wasm and raw AST round trips passed", flush=True)

    lines = 0
    for name in FIXTURES:
        source = ROOT / "test/selfhost" / (name + ".mere")
        expected = source.with_suffix(".expected")
        roundtrip(name, source)
        shutil.copyfile(expected, output / expected.name)
        lines += len(expected.read_bytes().splitlines())
    assert lines == 140
    print("  formatter fixtures: 11 programs / 140 oracle lines, interpreter/Wasm and idempotence passed", flush=True)

    source = ROOT / "test/selfhost/format_externs.mere"
    formatted = roundtrip("format_externs", source)
    expected = source.with_suffix(".expected").read_bytes()
    for input_file in [source, formatted]:
        for selfhost in [False, True]:
            prefix = ["node", ROOT / "scripts/run_wasm.js", compiler] if selfhost else [mere, "-w"]
            wat.write_bytes(run([*prefix, input_file]))
            target = work / "externs.wasm"
            run(["wat2wasm", "--enable-tail-call", wat, "-o", target])
            assert run(["node", ROOT / "scripts/selfhost_format_ffi.cjs", target]) == expected
    print("  formatter externs: reference/self-host Wasm preserve both handwritten host answers before/after formatting", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mere", type=Path, required=True)
    parser.add_argument("--compiler", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    check(args.mere.resolve(), args.compiler.resolve(), args.output.resolve())

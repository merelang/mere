#!/usr/bin/env python3
"""Require source refusals and logical tail calls from the self-host CLI."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def refused(result, reason):
    return result.returncode == 1 and reason in (result.stdout + result.stderr)


def run(args):
    return subprocess.run([str(arg) for arg in args], cwd=ROOT,
                          capture_output=True, text=True, timeout=120)


def succeeds(args):
    result = run(args)
    if result.returncode:
        raise AssertionError(f"command failed: {result.stdout[-1000:]}{result.stderr[-1000:]}")
    return result.stdout


def quoted(value):
    return json.dumps(str(value), ensure_ascii=False).replace("{", r"\{")


def check(mere, compiler):
    rows = [line.split("\t") for line in
            (ROOT / "test/selfhost/record_rejections.tsv").read_text().splitlines()]
    assert len(rows) == 9 and all(len(row) == 4 for row in rows), "record refusal inventory changed"
    assert len({row[0] for row in rows}) == 9
    type_rows = [line.split("\t") for line in
                 (ROOT / "test/selfhost/type_rejections.tsv").read_text().splitlines()]
    assert len(type_rows) == 19 and all(len(row) == 4 for row in type_rows), "type refusal inventory changed"
    assert len({row[0] for row in type_rows}) == 19
    rows = [[name, "-t", ref, own, source] for name, ref, own, source in rows + type_rows]
    declaration_rows = [line.split("\t") for line in
                        (ROOT / "test/selfhost/declaration_rejections.tsv").read_text().splitlines()]
    assert len(declaration_rows) == 28 and all(len(row) == 5 for row in declaration_rows), "declaration refusal inventory changed"
    assert len({row[0] for row in declaration_rows}) == 28
    assert all(row[1] in ("-t", "-w") for row in declaration_rows)
    rows += declaration_rows
    host = ROOT / "scripts/run_wasm.js"
    with tempfile.TemporaryDirectory(prefix="mere-record-check-") as temporary:
        work = Path(temporary)
        source, bridge = work / "input.mere", work / "typer.mere"
        for name, reference_mode, reference_reason, self_reason, text in rows:
            source.write_text(text + "\n")
            bridge.write_text("import " + quoted(ROOT / "contrib/typer/typer.mere")
                              + ";\nprint (parse_and_infer " + quoted(text) + ")\n")
            checks = [(run([mere, reference_mode, source]), reference_reason),
                      (run([mere, bridge]), self_reason),
                      (run(["node", host, compiler, source]), self_reason)]
            for result, reason in checks:
                assert refused(result, reason), (name, reason, result.returncode,
                                                 result.stdout[-500:], result.stderr[-500:])
            print(f"  source refusal {name}: reference, interpreted typer and compiled typer passed", flush=True)
        # An always-refusing tool cannot satisfy the gate. Also prove that the
        # CLI actually emits an executable module after its successful check.
        source.write_text("type R = { a: int, b: int }; (R { b = 23, a = 17 }).a\n")
        assert succeeds([mere, "-t", source]).strip() == "int"
        bridge.write_text("import " + quoted(ROOT / "contrib/typer/typer.mere")
                          + ";\nprint (parse_and_infer " + quoted(source.read_text()) + ")\n")
        assert succeeds([mere, bridge]).strip() == "int"
        wat, wasm = work / "positive.wat", work / "positive.wasm"
        wat.write_text(succeeds(["node", host, compiler, source]))
        succeeds(["wat2wasm", "--enable-tail-call", wat, "-o", wasm])
        assert succeeds(["node", host, wasm]) == "17\n"
        # Sharing the checked entry must preserve the browser's existing helper
        # implementations, including the map iterator's polymorphic map_head.
        prelude = ROOT / "test/selfhost/compiler_prelude.mere"
        expected = prelude.with_suffix(".expected").read_text()
        assert succeeds([mere, prelude]) == expected
        assert succeeds([mere, "-t", prelude]).strip() == "unit"
        bridge.write_text("import " + quoted(ROOT / "contrib/typer/typer.mere")
                          + ";\nimport " + quoted(ROOT / "contrib/codegen/codegen_wasm.mere")
                          + ";\nprint (parse_and_infer (selfhost_prelude_fns ++ "
                          + quoted(prelude.read_text()) + "))\n")
        assert succeeds([mere, bridge]).strip() == "unit"
        wat.write_text(succeeds(["node", host, compiler, prelude]))
        succeeds(["wat2wasm", "--enable-tail-call", wat, "-o", wasm])
        assert succeeds(["node", host, wasm]) == expected
        print("  standard helpers: 3 handwritten answers, source typing and target execution passed", flush=True)
        helper_rows = [line.split("\t") for line in
                       (ROOT / "test/selfhost/compiler_helpers.tsv").read_text().splitlines()]
        assert len(helper_rows) == 17 and all(len(row) == 3 for row in helper_rows)
        # Some browser helpers (such as list_mapi) are supplied by this Mere
        # catalog rather than the native prelude. Interpret the catalog as the
        # reference, independently checking each handwritten output oracle.
        bridge.write_text("import " + quoted(ROOT / "contrib/codegen/codegen_wasm.mere")
                          + ";\nprint selfhost_prelude_fns\n")
        catalog = succeeds([mere, bridge])
        # map_head is the self-host runtime's internal traversal primitive.
        # The native interpreter supplies map_iter directly instead.
        parts = catalog.rsplit("\nlet map_iter = fn m -> fn f ->", 1)
        assert len(parts) == 2 and parts[1].strip() == "list_iter (map_head m) (fn p -> f (fst p) (snd p));"
        catalog = parts[0] + "\n"
        reference = work / "reference.mere"
        for name, answers, text in helper_rows:
            source.write_text(text + "\n")
            reference.write_text(catalog + text + "\n")
            expected = "\n".join(json.loads(answers)) + "\n"
            assert succeeds([mere, reference]) == expected, name
            wat.write_text(succeeds(["node", host, compiler, source]))
            succeeds(["wat2wasm", "--enable-tail-call", wat, "-o", wasm])
            assert succeeds(["node", host, wasm]) == expected, name
        print("  helper inventory: 17 compatibility cases passed", flush=True)
        # Default Node stack and runtime memory limits stay in force. Check
        # both compiled routes; the evaluator has its own recursion strategy.
        source.write_text("let rec loop = fn n -> n == 0 || (n > 0 && loop (n - 1));\n"
                          "print (show (loop 50000))\n")
        for label, args in [("reference", [mere, "-w", source]),
                            ("self-host", ["node", host, compiler, source])]:
            wat.write_text(succeeds(args))
            succeeds(["wat2wasm", "--enable-tail-call", wat, "-o", wasm])
            assert succeeds(["node", host, wasm]) == "true\n", label
        print("  logical tail calls: 50000 steps on reference/self-host Wasm passed", flush=True)
    print("selfhost_record_check: 56 refusals on three paths, positive compilation and tail calls passed")


def self_test():
    reason = "field set mismatch"
    controls = [(0, reason, ""), (1, "parse error", ""), (-9, reason, ""), (1, "", "trap: unreachable")]
    for status, stdout, stderr in controls:
        assert not refused(subprocess.CompletedProcess([], status, stdout, stderr), reason)
    assert refused(subprocess.CompletedProcess([], 1, "fail: " + reason, ""), reason)
    assert refused(subprocess.CompletedProcess([], 1, "", "type error: " + reason), reason)
    print("selfhost_record_check: 4 false-refusal controls caught")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--mere", type=Path)
    parser.add_argument("--compiler", type=Path)
    args = parser.parse_args()
    if args.self_test:
        self_test()
    else:
        if args.mere is None or args.compiler is None:
            parser.error("--mere and --compiler are required")
        self_test()
        check(args.mere.resolve(), args.compiler.resolve())

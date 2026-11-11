#!/usr/bin/env python3
"""Execute signed extern and unsigned pointer/reference ABI contracts."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MERE = os.environ.get("MERE", str(ROOT / "_build/default/bin/mere.exe"))


def main():
    wat = subprocess.check_output([MERE, "-w", str(ROOT / "test/wasm_extern.mere")], text=True)
    names = ("ffi_echo", "ffi_alias", "ffi_first", "ffi_text", "ffi_handle", "ffi_bool", "ffi_unit")
    exports = "\n".join(f'(export "probe_{name}" (func ${name}))' for name in names)
    end = wat.rfind(")")
    if end < 0:
        raise RuntimeError("compiler emitted no module")
    wat = wat[:end] + exports + "\n" + wat[end:]
    mutations = {
        "healthy": None,
        "unsigned-int": ("i64.extend_i32_s (call $ffi_echo_h", "i64.extend_i32_u (call $ffi_echo_h"),
        "unsigned-partial": ("i64.extend_i32_s (call $ffi_first_h", "i64.extend_i32_u (call $ffi_first_h"),
        "signed-string": ("i64.extend_i32_u (call $ffi_text_h", "i64.extend_i32_s (call $ffi_text_h"),
        "signed-opaque": ("i64.extend_i32_u (call $ffi_handle_h", "i64.extend_i32_s (call $ffi_handle_h"),
        "lost-argument": ("(call $ffi_echo_h (i32.wrap_i64 (local.get 0)))", "(call $ffi_echo_h (i32.const 0))"),
    }
    with tempfile.TemporaryDirectory(prefix="mere-wasm-extern-") as directory:
        tmp = Path(directory)
        for label, mutation in mutations.items():
            text = wat
            if mutation:
                old, new = mutation
                if text.count(old) != 1:
                    raise RuntimeError(f"{label}: mutation must match exactly once")
                text = text.replace(old, new)
            source, binary = tmp / "probe.wat", tmp / "probe.wasm"
            source.write_text(text)
            subprocess.run(["wat2wasm", "--enable-tail-call", str(source), "-o", str(binary)], check=True)
            run = subprocess.run(["node", str(ROOT / "scripts/wasm_extern_check.mjs"), str(binary)],
                                 capture_output=True, text=True, timeout=30)
            if label == "healthy":
                if run.returncode or "wasm extern contract passed" not in run.stdout:
                    raise RuntimeError(run.stdout + run.stderr)
            elif not run.returncode or "AssertionError" not in run.stderr:
                raise RuntimeError(f"{label}: altered ABI was not rejected by an assertion\n" + run.stdout + run.stderr)
    print("wasm_extern: signed boundaries/aliases/partial application, unsigned string/opaque bits, bool/unit and arguments; 5 mutations caught")


if __name__ == "__main__":
    main()

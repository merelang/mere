#!/usr/bin/env python3
"""Audit compiler invocations in all-mode versus the three CI partitions.

The stubs deliberately have no program semantics. This checks shell routing;
the real emulator gates remain responsible for values, refusals and failures.
"""
from collections import Counter
from pathlib import Path
import os
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def main():
    with tempfile.TemporaryDirectory(prefix="rv-partition-") as d:
        tmp = Path(d)
        memu = tmp / "memu/riscv-runc"
        memu.mkdir(parents=True)
        for width in [32, 64]:
            (memu / f"rv{width}i_run.mere").touch()
        mere = tmp / "mere"
        mere.write_text("""#!/bin/sh
printf '%s\\t' "$@" >> "$MERE_TRACE"
printf '\\n' >> "$MERE_TRACE"
case "$*" in *str_edges.mere*) [ "$1" = -c ] && exit 1 ;; esac
case "$*" in *float_edges.mere*) [ "$1" = -rv ] && exit 1 ;; esac
printf 'stub\\n'
""")
        cc = tmp / "cc"
        cc.write_text("""#!/bin/sh
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then shift; out=$1; break; fi
  shift
done
printf '#!/bin/sh\\nexit 0\\n' > "$out"
chmod +x "$out"
""")
        mere.chmod(0o755)
        cc.chmod(0o755)
        source = (ROOT / "scripts/rv_exec_check.sh").read_text()

        def audit(source, mode, label):
            script = tmp / (label + ".sh")
            # Keep the real corpus, despite placing the instrumented shell in tmp.
            source = source.replace('ROOT="$(cd "$(dirname "$0")/.." && pwd)"',
                                    "ROOT=" + shlex.quote(str(ROOT)))
            source = source.replace('MERE="$ROOT/_build/default/bin/mere.exe"',
                                    'MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"')
            script.write_text(source)
            trace = tmp / (label + ".trace")
            env = dict(os.environ, MERE=str(mere), CC=str(cc), MEMU=str(memu.parent), MERE_TRACE=str(trace))
            result = subprocess.run(["sh", script, *mode], env=env, capture_output=True, timeout=300)
            if result.returncode not in [0, 1]:
                raise RuntimeError(result.stderr.decode())
            if mode == ["--corpus64"]:
                output = result.stdout.decode()
                assert "C backend vs RV64 on the Mere-written CPU" in output
                assert "nothing RAN" not in output and "C backend vs RV32I" not in output
            records = []
            for line in trace.read_text().splitlines():
                args = tuple(a.replace(str(ROOT) + "/", "") for a in line.rstrip("\t").split("\t"))
                if not any("/riscv-runc/" in a for a in args):
                    records.append(args)
            return Counter(records)

        whole = audit(source, [], "all")
        parts = Counter()
        for mode in ["--corpus32", "--corpus64", "--contracts"]:
            part = audit(source, [mode], mode[2:])
            assert part, mode
            parts += part
        assert whole == parts, ("partition mismatch", whole - parts, parts - whole)
        for width in [32, 64]:
            flag = "-rv" if width == 32 else "-rv64"
            assert any(flag in a and a[-1].startswith("test/parity/") for a in whole)
            assert any(flag in a and a[-1].startswith("test/rv/") for a in whole)
        if len(sys.argv) == 3 and sys.argv[1] == "--baseline":
            baseline = audit(Path(sys.argv[2]).read_text(), [], "baseline")
            assert baseline == whole, ("baseline mismatch", baseline - whole, whole - baseline)
        for mode in ["--corpus32", "--corpus64", "--contracts", "--typo"]:
            r = subprocess.run(["sh", ROOT / "scripts/rv_exec_check.sh", mode],
                               env=dict(os.environ, MERE=str(mere), MEMU=""), capture_output=True)
            assert r.returncode == 2, mode
        print(f"rv_exec_partition: {sum(whole.values())} fixture compiler invocations retained; three complementary partitions; missing runners and invalid modes refused")


if __name__ == "__main__":
    main()

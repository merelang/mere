#!/usr/bin/env python3
"""Check cache bounds and actual worker cleanup against generated C runtime."""
import os
from pathlib import Path
import resource
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MERE = os.environ.get("MERE", str(ROOT / "_build/default/bin/mere.exe"))
CC = os.environ.get("CC", "clang")


def main():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    with tempfile.TemporaryDirectory(prefix="mere-region-cache-") as directory:
        tmp = Path(directory)
        source = tmp / "runtime.mere"
        source.write_text("let h = spawn (fn () -> ()); let _ = join h; ()\n")
        runtime = subprocess.check_output([MERE, "-c", str(source)], text=True)
        fixture = ROOT / "test/regionreclaim/cache_contract.c"
        mutations = {
            "healthy": None,
            "old-depth": ("#define __LANG_REGION_CACHE_CAP 64", "#define __LANG_REGION_CACHE_CAP 8"),
            "over-depth": ("#define __LANG_REGION_CACHE_CAP 64", "#define __LANG_REGION_CACHE_CAP 65"),
            "grown-in-deep-slots": ("#define __LANG_REGION_CACHE_GROWN 8", "#define __LANG_REGION_CACHE_GROWN 64"),
            "unbounded-grown": ("#define __LANG_REGION_KEEP_MAX (16 * 1024 * 1024)",
                                "#define __LANG_REGION_KEEP_MAX (64 * 1024 * 1024)"),
            "worker-leak": ("while (__lang_region_cache_n > 0)", "while (0 && __lang_region_cache_n > 0)"),
        }
        for label, mutation in mutations.items():
            text = runtime
            if mutation:
                old, new = mutation
                if text.count(old) != 1:
                    raise RuntimeError(f"{label}: mutation no longer matches exactly once")
                text = text.replace(old, new)
            (tmp / "runtime.c").write_text(text)
            binary = tmp / "contracts"
            built = subprocess.run([CC, "-O1", "-w", "-pthread", "-I", str(tmp), str(fixture), "-o", str(binary)],
                                   capture_output=True, text=True, timeout=90)
            if built.returncode:
                if label == "over-depth" and "must be between 1 and 64" in built.stderr:
                    continue
                raise RuntimeError(f"{label}: fixture did not compile\n" + built.stderr)
            env = dict(os.environ)
            env.pop("MERE_REGION_STATS", None)
            run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30, env=env)
            if label == "healthy":
                if run.returncode != 0 or "region cache contracts passed" not in run.stdout:
                    raise RuntimeError(run.stdout + run.stderr)
            elif run.returncode == 0:
                raise RuntimeError(f"{label}: corrupted cache passed")
        (tmp / "runtime.c").write_text(runtime)
        configured_fixture = ROOT / "test/regionreclaim/cache_config_contract.c"
        for cap in [1, 4, 8, 64]:
            built = subprocess.run([CC, "-O1", "-w", "-pthread", f"-DMERE_REGION_CACHE_CAP={cap}",
                                    "-I", str(tmp), str(configured_fixture), "-o", str(binary)],
                                   capture_output=True, text=True, timeout=90)
            if built.returncode:
                raise RuntimeError(f"configured cap {cap}: did not compile\n" + built.stderr)
            run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30, env=env)
            if run.returncode or "configured region cache contracts passed" not in run.stdout:
                raise RuntimeError(f"configured cap {cap}: " + run.stdout + run.stderr)
        for cap in [0, -1, 65]:
            built = subprocess.run([CC, "-O1", "-w", "-pthread", f"-DMERE_REGION_CACHE_CAP={cap}",
                                    "-I", str(tmp), str(configured_fixture), "-o", str(binary)],
                                   capture_output=True, text=True, timeout=90)
            if not built.returncode or "must be between 1 and 64" not in built.stderr:
                raise RuntimeError(f"invalid cap {cap}: was not rejected by the runtime bound")
        print("region_cache: depth 8/9/40/63/64/65/80/128, mixed/grown bounds, TLS isolation and normal/failed worker cleanup; 5 mutations caught; configured caps 1/4/8/64 pass, invalid caps rejected")


if __name__ == "__main__":
    main()

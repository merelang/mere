#!/usr/bin/env python3
"""Run the cross-language benchmark suite and print the record.

WHAT THIS IS. A record, not a verdict. It measures the same program written
in several languages and prints what each one did, with the version of every
implementation in the header. There is no threshold here and nothing fails
because a number moved -- the deterministic part of this suite, the part that
can be a gate, lives in scripts/bench_check.sh.

WHY IT LOOKS LIKE THIS.

* Every implementation must print the SAME BYTES before any timing is
  reported. A benchmark where the implementations disagree is measuring two
  different programs, and the disagreement always shows up as a suspiciously
  good number for whichever one is doing less work. A mismatch is printed and
  the row is dropped from the timing table -- never silently, and never
  normalized away.

* Wall clock is reported as a median AND a band. A single number invites the
  reader to compare digits that are not there.

* Peak RSS is reported as a band for a harder reason: it is quantized (the
  region allocator doubles) and above a few GB it stops reproducing at all --
  the same binary on the same input has been measured at 6.2 GB and 15.8 GB.
  So RSS is reported, and a DETERMINISTIC column is reported next to it for
  Mere: `alloc` is the region allocator's cumulative byte count from
  MERE_REGION_STATS, which is a function of the program and not of the
  machine. When the two disagree about a change, alloc is the one to believe.

* A missing toolchain prints a skip line. It never silently disappears: a
  suite that quietly drops the fast competitor reads as a win.

Usage:
    python3 benchmarks/run.py                 # every benchmark
    python3 benchmarks/run.py crc32 wordfreq  # a subset
    python3 benchmarks/run.py --reps 9
    python3 benchmarks/run.py --verify-only   # the deterministic half only
"""

import argparse
import os
import platform
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
MERE = os.path.join(ROOT, "_build", "default", "bin", "mere.exe")
BUILD = os.path.join(HERE, ".build")

# ru_maxrss is bytes on macOS and kilobytes on Linux. The units differ and
# nothing in the API says so; reading it raw is a 1024x error on one of the
# two platforms.
MAXRSS_UNIT = 1 if sys.platform == "darwin" else 1024

CC = os.environ.get("CC", "cc")


# --------------------------------------------------------------------------
# toolchains
# --------------------------------------------------------------------------

class Tool:
    """One language toolchain: how to check it, build with it, and name it."""

    def __init__(self, key, label, probe, version_cmd, build, run):
        self.key = key            # ref.<key>, or "mere"
        self.label = label        # column label
        self.probe = probe        # executable that must exist
        self.version_cmd = version_cmd
        self.build = build        # (src, out) -> argv or None (interpreted)
        self.run = run            # (src, out, args) -> argv
        self._version = None

    def available(self):
        if self.key == "mere":
            return os.path.exists(MERE)
        return shutil.which(self.probe) is not None

    def version(self):
        if self._version is None:
            self._version = self._read_version()
        return self._version

    def _read_version(self):
        try:
            out = subprocess.run(self.version_cmd, capture_output=True, text=True,
                                 timeout=30)
            text = (out.stdout or "") + (out.stderr or "")
            return text.strip().splitlines()[0].strip()
        except Exception as e:               # noqa: BLE001 - reported, not raised
            return "unknown (%s)" % e


def _mere_build(src, out):
    return None  # handled specially: mere -c, then CC


def _tools():
    return [
        Tool("mere", "mere (C backend)", MERE,
             [MERE, "--version"],
             _mere_build,
             lambda s, o, a: [o] + a),
        Tool("c", "C", CC,
             [CC, "--version"],
             lambda s, o: [CC, "-O2", "-w", s, "-o", o],
             lambda s, o, a: [o] + a),
        Tool("rs", "Rust", "rustc",
             ["rustc", "--version"],
             lambda s, o: ["rustc", "-O", "-A", "warnings", s, "-o", o],
             lambda s, o, a: [o] + a),
        Tool("go", "Go", "go",
             ["go", "version"],
             lambda s, o: ["go", "build", "-o", o, s],
             lambda s, o, a: [o] + a),
        Tool("js", "Node", "node",
             ["node", "--version"],
             lambda s, o: None,
             lambda s, o, a: ["node", s] + a),
        Tool("rb", "Ruby", "ruby",
             ["ruby", "--version"],
             lambda s, o: None,
             lambda s, o, a: ["ruby", s] + a),
        Tool("py", "Python", "python3",
             ["python3", "--version"],
             lambda s, o: None,
             lambda s, o, a: ["python3", s] + a),
    ]


# --------------------------------------------------------------------------
# measurement
# --------------------------------------------------------------------------

class Run:
    def __init__(self, wall, maxrss, out, rc, err):
        self.wall = wall
        self.maxrss = maxrss
        self.out = out
        self.rc = rc
        self.err = err


def measure(argv, cwd, env=None, timeout=600):
    """One process, wall clock and peak RSS from the kernel.

    os.wait4 gives this child's rusage directly, so no /usr/bin/time is
    involved and there is no GNU-vs-BSD flag to get wrong. Wall clock is
    perf_counter around the whole process, which is what the "short-lived
    program" claim is about: runtime startup is part of the measurement, not
    something to subtract.
    """
    e = dict(os.environ)
    if env:
        e.update(env)
    rd, wd = os.pipe()
    rde, wde = os.pipe()
    t0 = time.perf_counter()
    pid = os.fork()
    if pid == 0:                              # child
        try:
            os.close(rd); os.close(rde)
            os.dup2(wd, 1); os.dup2(wde, 2)
            os.close(wd); os.close(wde)
            os.chdir(cwd)
            os.execvpe(argv[0], argv, e)
        except Exception:
            os._exit(127)
    os.close(wd); os.close(wde)
    chunks, echunks = [], []
    # Drain both pipes before waiting, or a chatty child fills the buffer and
    # deadlocks against our wait4 -- a benchmark harness that hangs is worse
    # than one that fails.
    import selectors
    sel = selectors.DefaultSelector()
    sel.register(rd, selectors.EVENT_READ, chunks)
    sel.register(rde, selectors.EVENT_READ, echunks)
    open_fds = 2
    deadline = t0 + timeout
    while open_fds:
        if time.perf_counter() > deadline:
            os.kill(pid, 9)
            break
        for key, _ in sel.select(timeout=1.0):
            data = os.read(key.fd, 65536)
            if not data:
                sel.unregister(key.fd)
                os.close(key.fd)
                open_fds -= 1
            else:
                key.data.append(data)
    _, status, ru = os.wait4(pid, 0)
    wall = time.perf_counter() - t0
    rc = os.WEXITSTATUS(status) if os.WIFEXITED(status) else -os.WTERMSIG(status)
    return Run(wall, ru.ru_maxrss * MAXRSS_UNIT,
               b"".join(chunks).decode("utf-8", "replace"),
               rc,
               b"".join(echunks).decode("utf-8", "replace"))


# --------------------------------------------------------------------------
# benchmarks
# --------------------------------------------------------------------------

def read_manifest(path):
    """key = value, with indented continuation lines appended to the previous
    key -- so a `claim` can be a paragraph and still live next to the code it
    describes."""
    m = {}
    last = None
    with open(path) as f:
        for raw in f:
            line = raw.split("#", 1)[0].rstrip()
            if not line.strip():
                continue
            if raw[:1] in (" ", "\t") and last:
                m[last] += " " + line.strip()
                continue
            if "=" not in line:
                continue
            k, v = line.split("=", 1)
            last = k.strip()
            m[last] = v.strip()
    return m


class Impl:
    def __init__(self, tool, src, label):
        self.tool = tool
        self.src = src
        self.label = label
        self.exe = None
        self.runs = []
        self.status = "ok"
        self.note = ""


def discover(bench_dir, tools):
    """Implementations of one benchmark, in the order they should be reported.

    Mere first (it is the subject), then the compiled languages, then the
    managed ones -- so the table reads from the thing being measured outward.
    """
    impls = []
    by_key = {t.key: t for t in tools}
    for fn in sorted(os.listdir(bench_dir)):
        if fn == "bench.mere":
            impls.append(Impl(by_key["mere"], os.path.join(bench_dir, fn),
                              by_key["mere"].label))
        elif fn.startswith("bench_") and fn.endswith(".mere"):
            variant = fn[len("bench_"):-len(".mere")]
            impls.append(Impl(by_key["mere"], os.path.join(bench_dir, fn),
                              "mere (%s)" % variant))
    order = ["c", "rs", "go", "js", "rb", "py"]
    for key in order:
        src = os.path.join(bench_dir, "ref." + key)
        if os.path.exists(src):
            impls.append(Impl(by_key[key], src, by_key[key].label))
    return impls


def build(impl, outdir):
    os.makedirs(outdir, exist_ok=True)
    base = os.path.splitext(os.path.basename(impl.src))[0]
    out = os.path.join(outdir, "%s.%s" % (base, impl.tool.key))

    if impl.tool.key == "mere":
        cfile = out + ".c"
        r = subprocess.run([MERE, "-c", impl.src], capture_output=True, text=True)
        if r.returncode != 0:
            impl.status = "build-failed"
            impl.note = "mere -c: " + (r.stderr.strip().splitlines() or [""])[0]
            return False
        with open(cfile, "w") as f:
            f.write(r.stdout)
        r = subprocess.run([CC, "-O2", "-w", cfile, "-o", out],
                           capture_output=True, text=True)
        if r.returncode != 0:
            impl.status = "build-failed"
            impl.note = "cc: " + (r.stderr.strip().splitlines() or [""])[0]
            return False
        impl.exe = out
        return True

    cmd = impl.tool.build(impl.src, out)
    if cmd is None:                            # interpreted
        impl.exe = None
        return True
    env = dict(os.environ)
    if impl.tool.key == "go":
        # Go refuses to build outside a module and writes its caches under
        # $HOME; both are set here so a run leaves nothing behind and does not
        # depend on the developer's Go setup.
        env["GO111MODULE"] = "off"
        env["GOCACHE"] = os.path.join(BUILD, "gocache")
        env["GOFLAGS"] = ""
    r = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if r.returncode != 0:
        impl.status = "build-failed"
        impl.note = (r.stderr.strip().splitlines() or [""])[-1]
        return False
    impl.exe = out
    return True


def fmt_bytes(n):
    if n >= 1 << 30:
        return "%.2f GiB" % (n / float(1 << 30))
    if n >= 1 << 20:
        return "%.1f MiB" % (n / float(1 << 20))
    if n >= 1024:
        return "%.0f KiB" % (n / 1024.0)
    return "%d B" % n          # not "0 KiB": a rounded zero reads as "none"


def region_alloc(impl, args, cwd):
    """The deterministic Mere column: cumulative region allocation.

    MERE_REGION_STATS prints this on stderr at exit on the C backend. Unlike
    peak RSS it is a function of the program, so it is the number to compare
    across commits.

    THE METER'S SCOPE. It reports the DEFAULT region only. A program that does
    its allocating inside a named arena -- `region R { }` or `region R loop`,
    which is to say the programs that manage memory deliberately -- reads as a
    few hundred bytes here, and a few hundred bytes formatted as "0 KiB" reads
    as "allocated nothing". That is how this column first reported the
    region-loop row. Until the meter can see named arenas, such a row is
    flagged rather than printed as a number that means the opposite of the
    truth.
    """
    if impl.tool.key != "mere" or impl.exe is None:
        return None, False
    # Matched against the source with `//` comments stripped: the first
    # version of this test grepped for the word "region" and flagged the
    # NAIVE program, whose comment explains what a region is. A detector that
    # reads prose puts the disclaimer on the row that does not need it and
    # makes the flag meaningless on the row that does.
    src = "\n".join(l.split("//", 1)[0] for l in open(impl.src).read().splitlines())
    named = re.search(r"\bregion\s+\w+\s*(loop\b|\{)", src) is not None
    r = measure([impl.exe] + args, cwd, env={"MERE_REGION_STATS": "1"})
    for line in r.err.splitlines():
        if line.startswith("region-stats default:"):
            for tok in line.split():
                if tok.startswith("alloc_total="):
                    return int(tok.split("=", 1)[1]), named
    return None, False


def run_bench(name, bench_dir, tools, reps, verify_only, do_sweep=False):
    man = read_manifest(os.path.join(bench_dir, "MANIFEST"))
    args = man.get("args", "").split()
    args = [a.replace("$DATA", os.path.join(HERE, "data")) for a in args]
    cwd = HERE

    print("")
    print("### %s — %s" % (name, man.get("shape", "")))
    print("")
    if man.get("claim"):
        print("claim: %s" % man["claim"])
        print("")

    impls = discover(bench_dir, tools)
    live = []
    broken = False
    for impl in impls:
        if not impl.tool.available():
            print("  skip %-20s toolchain absent (%s)" % (impl.label, impl.tool.probe))
            continue
        if not build(impl, os.path.join(BUILD, name)):
            print("  FAIL %-20s %s: %s" % (impl.label, impl.status, impl.note))
            # A build failure is a failure of the run, not a row that quietly
            # disappears. The first version of this runner printed the line
            # above and then reported "every implementation printed the same
            # bytes" -- with the subject of the suite missing from the table.
            broken = True
            continue
        live.append(impl)

    if not live:
        print("  nothing to run")
        return {"name": name, "impls": [], "mismatch": True}

    # --- the same-answer check, before any timing is believed -------------
    baseline = None
    expect_path = os.path.join(bench_dir, "expect.txt")
    if os.path.exists(expect_path):
        with open(expect_path) as f:
            baseline = f.read()
        baseline_from = "expect.txt"
    agreeing = []
    mismatch = broken
    for impl in live:
        argv = impl.tool.run(impl.src, impl.exe, args)
        r = measure(argv, cwd)
        if r.rc != 0:
            impl.status = "exit %d" % r.rc
            print("  FAIL %-20s exited %d: %s" % (impl.label, r.rc,
                                                  r.err.strip()[:120]))
            mismatch = True
            continue
        if baseline is None:
            baseline = r.out
            baseline_from = impl.label
        if r.out != baseline:
            impl.status = "MISMATCH"
            mismatch = True
            print("  MISMATCH %-16s its output differs from %s -- excluded from the"
                  " timings" % (impl.label, baseline_from))
            print("      %s said: %r" % (baseline_from, baseline[:120]))
            print("      %s said: %r" % (impl.label, r.out[:120]))
            continue
        agreeing.append(impl)

    print("  same-answer: %d/%d implementations agree with %s"
          % (len(agreeing), len(live), baseline_from))

    # --- the deterministic bound, the only thing here fit to be a gate ------
    lo = man.get("alloc_min")
    hi = man.get("alloc_max")
    if lo and hi:
        for impl in agreeing:
            if impl.tool.key != "mere":
                continue
            alloc, named = region_alloc(impl, args, cwd)
            if named:
                print("  alloc %-22s named arena -- unmetered, no bound"
                      % impl.label)
                continue
            if alloc is None:
                print("  FAIL  %-22s MERE_REGION_STATS printed nothing: the"
                      " meter is broken, not the program" % impl.label)
                mismatch = True
                continue
            lo_i, hi_i = int(lo), int(hi)
            if alloc < lo_i:
                print("  FAIL  %-22s alloc_total=%d is BELOW the floor %d --"
                      " the meter stopped seeing its subject"
                      % (impl.label, alloc, lo_i))
                mismatch = True
            elif alloc > hi_i:
                print("  FAIL  %-22s alloc_total=%d exceeds %d -- this program"
                      " now allocates more than it did" % (impl.label, alloc, hi_i))
                print("        (if this moved with the PLATFORM and not with a"
                      " change, the bound needs a")
                print("         platform split -- alloc_total should be a"
                      " function of the program alone.)")
                mismatch = True
            else:
                print("  alloc %-22s %d B, within [%d, %d]"
                      % (impl.label, alloc, lo_i, hi_i))

    if verify_only:
        return {"name": name, "impls": agreeing, "mismatch": mismatch}

    # --- timings -----------------------------------------------------------
    for impl in agreeing:
        argv = impl.tool.run(impl.src, impl.exe, args)
        for _ in range(reps):
            impl.runs.append(measure(argv, cwd))
        impl.alloc, impl.named_region = region_alloc(impl, args, cwd)

    print("")
    print("  | implementation | wall median | wall band | peak RSS |"
          " default-region alloc (deterministic) |")
    print("  |---|---|---|---|---|")
    footnote = False
    for impl in agreeing:
        walls = sorted(r.wall for r in impl.runs)
        rsses = sorted(r.maxrss for r in impl.runs)
        med = walls[len(walls) // 2]
        band = "%.0f–%.0f ms" % (walls[0] * 1000, walls[-1] * 1000)
        rss = fmt_bytes(rsses[len(rsses) // 2])
        if fmt_bytes(rsses[0]) != fmt_bytes(rsses[-1]):
            rss += " (%s–%s)" % (fmt_bytes(rsses[0]), fmt_bytes(rsses[-1]))
        alloc = fmt_bytes(impl.alloc) if getattr(impl, "alloc", None) else "—"
        if getattr(impl, "named_region", False):
            alloc = "%s + named arena (unmetered) ✱" % alloc
            footnote = True
        print("  | %s | %.0f ms | %s | %s | %s |"
              % (impl.label, med * 1000, band, rss, alloc))
    if do_sweep and man.get("sweep"):
        sweep(name, bench_dir, agreeing, man, cwd, reps)

    if footnote:
        print("")
        print("  ✱ MERE_REGION_STATS reports the DEFAULT region only. A program"
              " that allocates inside")
        print("    a named arena is invisible to it, so for those rows peak RSS"
              " is the only memory")
        print("    figure here -- and peak RSS is the one that does not"
              " reproduce. The deterministic")
        print("    meter cannot yet see the construct that exists to manage"
              " memory.")
    return {"name": name, "impls": agreeing, "mismatch": mismatch}


def sweep(name, bench_dir, impls, man, cwd, reps):
    """Run one benchmark across a series of argument sets.

    A single row says how long something took; a sweep says what it is a
    function of. The churn benchmark exists because of what its sweep shows --
    that one implementation's cost per operation grows with the size of the
    table and the others' does not -- and that is not visible in any single
    measurement, however carefully it is banded.
    """
    sets = [a.strip().split() for a in man["sweep"].split("|")]
    print("")
    print("  sweep over `%s`:" % man.get("sweep_axis", "args"))
    print("")
    header = " | ".join(" ".join(a) for a in sets)
    print("  | implementation | %s |" % header)
    print("  |---%s" % ("|---" * len(sets)) + "|")
    for impl in impls:
        cells = []
        for a in sets:
            args = [x.replace("$DATA", os.path.join(HERE, "data")) for x in a]
            walls = sorted(measure(impl.tool.run(impl.src, impl.exe, args),
                                   cwd).wall for _ in range(reps))
            cells.append("%.0f ms" % (walls[len(walls) // 2] * 1000))
        print("  | %s | %s |" % (impl.label, " | ".join(cells)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("benches", nargs="*")
    ap.add_argument("--reps", type=int, default=5)
    ap.add_argument("--verify-only", action="store_true",
                    help="the deterministic half: build and same-answer only")
    ap.add_argument("--sweep", action="store_true",
                    help="also run each benchmark's scaling sweep, if it has one")
    opts = ap.parse_args()

    if not os.path.exists(MERE):
        print("mere.exe not found at %s — run 'dune build' first" % MERE,
              file=sys.stderr)
        # The gate that inspects a stale binary passes forever; refuse instead.
        return 2

    subprocess.run([sys.executable, os.path.join(HERE, "gen_data.py")],
                   check=True, capture_output=True)

    tools = _tools()
    names = opts.benches or sorted(
        d for d in os.listdir(HERE)
        if os.path.exists(os.path.join(HERE, d, "MANIFEST")))

    print("# mere benchmark record")
    print("")
    print("host: %s %s, %s" % (platform.system(), platform.machine(),
                               platform.processor() or "cpu unknown"))
    print("reps: %d per implementation" % opts.reps)
    print("")
    print("Implementations, by name and version — a comparison against"
          " \"Go\" is not a")
    print("comparison; a comparison against the line below is:")
    print("")
    for t in tools:
        if t.available():
            extra = ""
            if t.key == "mere":
                extra = "  [mere -c | %s -O2]" % CC
            elif t.key == "c":
                extra = "  [-O2]"
            elif t.key == "rs":
                extra = "  [-O]"
            print("  %-16s %s%s" % (t.label, t.version(), extra))
        else:
            print("  %-16s ABSENT — its rows are skipped, not omitted" % t.label)

    any_mismatch = False
    for name in names:
        d = os.path.join(HERE, name)
        if not os.path.exists(os.path.join(d, "MANIFEST")):
            print("no such benchmark: %s" % name, file=sys.stderr)
            return 2
        res = run_bench(name, d, tools, opts.reps, opts.verify_only,
                        opts.sweep)
        any_mismatch = any_mismatch or res["mismatch"]

    print("")
    if any_mismatch:
        print("RESULT: at least one implementation disagreed or failed to run."
              " The timings above are not a comparison until that is resolved.")
        return 1
    print("RESULT: every implementation printed the same bytes.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Exercise coroutine runner overlap, isolation and process-family cleanup."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

RUNNER = Path(__file__).with_name("coro_rv_runner.pl")
FAKE = r'''
import json, os, pathlib, sys, time
job = json.loads(pathlib.Path("prog.bin").read_text())
root = pathlib.Path(job["root"])
width = job["width"]
if job["mode"] == "overlap":
    (root / ("start" + width)).touch()
    until = time.monotonic() + 5
    while not (root / ("start" + job["peer"])).exists():
        if time.monotonic() > until:
            sys.exit(99)
        time.sleep(.01)
elif job["mode"] in ("family", "leader-exits"):
    child = os.fork()
    if child == 0:
        time.sleep(60)
        os._exit(0)
    (root / ("pids" + width)).write_text(json.dumps([os.getpid(), child]))
    if job["mode"] == "family":
        time.sleep(60)
print("output-" + width, flush=True)
sys.exit(job.get("exit", 0))
'''


class RunnerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Reap orphaned fake grandchildren ourselves on Linux, including in
        # containers whose PID 1 does not reap them. macOS uses launchd.
        if sys.platform.startswith("linux"):
            import ctypes
            if ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) != 0:
                raise RuntimeError("cannot become a child subreaper")

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="coro-runner-")
        self.root = Path(self.temp.name)
        self.fake = self.root / "runner"
        self.fake.write_text("#!" + sys.executable + "\n" + FAKE)
        self.fake.chmod(0o755)
        self.processes = []

    def tearDown(self):
        for process in self.processes:
            if process.poll() is None:
                process.terminate()
                process.communicate(timeout=5)
        for record in self.root.glob("pids*"):
            leader, child = json.loads(record.read_text())
            try:
                os.killpg(leader, signal.SIGKILL)
            except ProcessLookupError:
                pass
            self.assert_stopped(child)
        self.temp.cleanup()

    def job(self, width, mode="exit", **extra):
        directory = self.root / width
        directory.mkdir()
        (directory / "prog.bin").write_text(json.dumps(dict(
            root=str(self.root), width=width, mode=mode, **extra)))
        return [width, "case-" + width, str(directory), str(self.fake), "256"]

    def launch(self, *jobs, limit=5, timings=None):
        env = os.environ.copy()
        env.pop("CORO_TIMINGS", None)
        if timings is not None:
            env["CORO_TIMINGS"] = str(timings)
        process = subprocess.Popen(
            ["perl", str(RUNNER), str(limit)] + sum(jobs, []),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        self.processes.append(process)
        return process

    def finish(self, process, expected=0):
        output, error = process.communicate(timeout=10)
        self.assertEqual(process.returncode, expected, output + error)
        return error

    def await_pids(self, width):
        record = self.root / ("pids" + width)
        until = time.monotonic() + 5
        while not record.exists() or not record.read_text():
            self.assertLess(time.monotonic(), until, "runner never started")
            time.sleep(.01)
        return json.loads(record.read_text())

    def assert_stopped(self, pid):
        until = time.monotonic() + 5
        while True:
            try:
                os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                pass
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
            self.assertLess(time.monotonic(), until, "runner descendant survived")
            time.sleep(.01)

    def test_both_widths_overlap_with_isolated_output_and_timings(self):
        a = self.job("64", "overlap", peer="32")
        b = self.job("32", "overlap", peer="64")
        timings = self.root / "timings.tsv"
        self.finish(self.launch(a, b, timings=timings))
        for width in ("64", "32"):
            self.assertEqual((self.root / width / "out").read_text(), "output-" + width + "\n")
            self.assertEqual((self.root / width / "status").read_text(), "0\n")
        records = [line.split("\t") for line in timings.read_text().splitlines()]
        self.assertEqual({r[0] for r in records}, {"execute-rv64", "execute-rv32"})
        self.assertEqual(len(records), 2)
        self.assertTrue(all(float(r[2]) >= 0 and r[3] == "0" for r in records))

    def test_program_failure_is_status_data(self):
        self.finish(self.launch(self.job("64", exit=7)))
        self.assertEqual((self.root / "64/status").read_text(), "7\n")

    def test_launch_failure_is_infrastructure_failure(self):
        self.fake.write_text("#!/missing/coro-test-interpreter\n")
        error = self.finish(self.launch(self.job("64")), expected=2)
        self.assertIn("did not launch", error)

    def test_timeout_kills_descendants(self):
        process = self.launch(self.job("64", "family"), limit=1)
        leader, child = self.await_pids("64")
        self.finish(process)
        self.assertEqual((self.root / "64/status").read_text(), "142\n")
        self.assert_stopped(leader)
        self.assert_stopped(child)

    def test_cancellation_kills_both_process_families(self):
        process = self.launch(self.job("64", "family"), self.job("32", "family"))
        pids = self.await_pids("64") + self.await_pids("32")
        process.terminate()
        self.finish(process, expected=143)
        for pid in pids:
            self.assert_stopped(pid)

    def test_finished_leader_does_not_leave_descendants(self):
        process = self.launch(self.job("64", "leader-exits"))
        leader, child = self.await_pids("64")
        self.finish(process)
        self.assert_stopped(leader)
        self.assert_stopped(child)

    def test_result_write_failure_cleans_up_other_worker(self):
        a = self.job("64", "overlap", peer="32")
        b = self.job("32", "family")
        (self.root / "64/status").mkdir()
        process = self.launch(a, b)
        _, child = self.await_pids("32")
        (self.root / "start32").touch()
        self.finish(process, expected=2)
        self.assert_stopped(child)

    def test_timing_write_failure_is_infrastructure_failure(self):
        self.finish(self.launch(self.job("64"), timings=self.root), expected=2)

    def test_rejects_duplicate_width(self):
        job = self.job("64")
        self.finish(self.launch(job, job), expected=255)

    def test_rejects_more_than_two_jobs(self):
        job = self.job("64")
        self.finish(self.launch(job, job, job), expected=255)


if __name__ == "__main__":
    unittest.main()

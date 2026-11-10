#!/usr/bin/env python3
"""Check bounded Map case scheduling and propagation of failures/timeouts."""
import subprocess
import threading

from rv_map_owner_check import compare_in_batches, fixtures


def main():
    assert len(fixtures()) == 254
    lock = threading.Lock()
    barrier = threading.Barrier(2)
    active = peak = 0
    calls = []

    def compare(case):
        nonlocal active, peak
        with lock:
            active += 1
            peak = max(peak, active)
            calls.append(case)
        try:
            # Synchronize rather than relying on sleeps to observe overlap.
            barrier.wait(timeout=10)
            return case
        finally:
            with lock:
                active -= 1

    assert list(compare_in_batches(range(8), compare, 2)) == list(range(8))
    assert sorted(calls) == list(range(8)) and peak == 2 and active == 0
    assert list(compare_in_batches(range(5), lambda case: case, 2)) == list(range(5))
    assert list(compare_in_batches([], lambda case: case, 2)) == []
    calls.clear()
    def serial(case):
        calls.append(case)
        return case
    assert list(compare_in_batches(range(8, 12), serial, 1)) == list(range(8, 12))
    assert calls == list(range(8, 12))
    controls = 0
    for workers in (1, 2):
        for failed_case, failure in [(case, error) for case in (0, 1) for error in (
                RuntimeError("C/RISC-V mismatch"), subprocess.TimeoutExpired("fixture", 60))]:
            calls = []

            def broken(case):
                calls.append(case)
                if case == failed_case:
                    raise failure
                return case

            try:
                list(compare_in_batches(range(10), broken, workers))
            except type(failure) as error:
                assert error is failure and failed_case in calls and set(calls) <= {0, 1}
                controls += 1
            else:
                raise RuntimeError("a failed case was hidden")
    for invalid in (0, 3):
        try:
            list(compare_in_batches([], lambda x: x, invalid))
        except ValueError:
            controls += 1
        else:
            raise RuntimeError("an unbounded worker count was accepted")
    print(f"rv_map_runner_check: bounded workers and complete ordered results; {controls} failure controls passed")


if __name__ == "__main__":
    main()

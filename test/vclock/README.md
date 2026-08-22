Programs for `scripts/virtual_clock_check.sh`.

Each file's first line declares what the run under `MERE_VIRTUAL_CLOCK=1` must do:

    //! expect: ok            stdout must equal <case>.expected, twice in a row
    //! expect: fail <text>   the run must fail, and stderr must contain <text>

Every case's virtual waits add up to well past the gate's wall-clock bound, so a
clock that is secretly real does not pass slowly -- it gets killed and FAILs.

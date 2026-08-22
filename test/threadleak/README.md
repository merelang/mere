Programs for `scripts/thread_leak_check.sh`.

Each file's first line is a comment naming what the run is supposed to report:

    //! leaks: 0
    //! leaks: 1 blocked on channel_recv

The gate reads that line and compares it against what the interpreter actually
says with `MERE_THREAD_REPORT=1`. The expectation lives next to the program
rather than in the script so that adding a case does not mean editing the gate.

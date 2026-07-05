// scripts/subprocess_env.js — synchronous subprocess exec.
//
// Companion of scripts/http_fetch_env.js. Provides three externs for
// Mere programs that need to shell out to a system tool (curl, git,
// jq, ffmpeg, another Mere .wasm) and read its stdout back.
//
// Deliberately sync: builds on child_process.spawnSync, blocks the
// whole Wasm frame until the child exits. For genuinely parallel
// subprocess execution (spawn N children, collect concurrently),
// see the trade-off note at the bottom of contrib/os/subprocess.mere.
// Short version: parallel needs the worker_threads restructure that
// Q-012 step 3 (post-narrow) will bring; today's shape is "one child
// at a time, but shell backgrounding + tmpfiles works as a stopgap".
//
// Externs:
//
//   subprocess_run     cmd stdin -> str   (stdout of the child)
//   subprocess_status  ()        -> int   (exit code of the LAST run)
//   subprocess_stderr  ()        -> str   (stderr of the LAST run)
//
// Semantics:
//   - `cmd` runs through the user's shell (spawnSync `shell: true`).
//     That means shell metachars work; that also means the caller is
//     responsible for quoting untrusted input.
//   - `stdin` is written to the child's stdin (and stdin is closed).
//   - Timeout is 30 s. Long-running children should either background
//     inside the shell or refactor to a proper worker model.
//   - Buffer cap is 16 MiB per stream.
//
// Factory shape mirrors makeHttpFetchEnv:
//
//   const { extras } = makeSubprocessEnv({ readCStr, writeStr });
//   Object.assign(env, extras);

const { spawnSync } = require("child_process");

function makeSubprocessEnv({ readCStr, writeStr }) {
  let lastStatus = 0;
  let lastStderr = "";

  return {
    subprocess_run: (cmdPtr, stdinPtr) => {
      const cmd = readCStr(cmdPtr);
      const stdin = readCStr(stdinPtr);
      const result = spawnSync(cmd, {
        input: stdin,
        shell: true,
        encoding: "utf8",
        maxBuffer: 16 * 1024 * 1024,
        timeout: 30000,
      });
      // status is null on signal / timeout; treat as -1 so callers
      // can distinguish from a normal nonzero exit.
      lastStatus = result.status ?? -1;
      lastStderr = result.stderr || "";
      return writeStr(result.stdout || "");
    },
    subprocess_status: () => lastStatus,
    subprocess_stderr: () => writeStr(lastStderr),
  };
}

module.exports = { makeSubprocessEnv };

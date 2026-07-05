// scripts/http_fetch_env.js — outbound HTTP externs (curl-based).
//
// Shared between `run_http_server.js` and `run_wasm.js` so any Mere
// program that declares `extern fn http_fetch: ...` can make outbound
// calls, regardless of which runner started it. Previously this lived
// inline in run_http_server.js only, meaning plain wasm programs
// under run_wasm.js couldn't call out.
//
// The runner has to supply three closures — the extern env can't see
// the module's private state directly — so wire them in via factory:
//
//   const { extras: fetchExtras } = makeHttpFetchEnv({
//     readCStr,
//     writeStr,
//   });
//   Object.assign(env, fetchExtras);
//
// Exposes five externs on the env object:
//
//   http_fetch(method, url, body)        -> body
//   http_fetch_status()                  -> int
//   http_fetch_add_header(name, value)   -> int    (0)
//   http_fetch_response_header(name)     -> str    ("" if absent)
//   http_fetch_set_timeout(ms)           -> int    (0)
//
// Depends on `curl` being on PATH (macOS / Linux default; also present
// in most Docker base images). Request body is sent via
// `--data-binary` when non-empty; response headers are captured via
// `-i` and parsed out of stdout so the host doesn't need a temp file.
// Redirect chains and 100-continue prefaces are handled by taking the
// LAST HTTP/… header block.

const { spawnSync } = require("child_process");

function makeHttpFetchEnv({ readCStr, writeStr }) {
  let lastFetchStatus = 0;
  let lastFetchHeaders = new Map();
  let nextFetchHeaders = [];
  let nextFetchTimeoutMs = 0;

  const http_fetch = (methodPtr, urlPtr, bodyPtr) => {
    const method = readCStr(methodPtr) || "GET";
    const url = readCStr(urlPtr);
    const body = readCStr(bodyPtr);
    // `-i` includes response headers before the body separated by a
    // blank line so we can capture them without a temp file.
    const args = ["-sS", "-i", "-w", "\n__STATUS__%{http_code}", "-X", method];
    for (const [k, v] of nextFetchHeaders) args.push("-H", `${k}: ${v}`);
    nextFetchHeaders = [];
    if (body && body.length > 0) args.push("--data-binary", body);
    args.push(url);
    const timeoutMs = nextFetchTimeoutMs > 0 ? nextFetchTimeoutMs : 10000;
    nextFetchTimeoutMs = 0;
    const result = spawnSync("curl", args, {
      encoding: "utf8",
      timeout: timeoutMs,
      maxBuffer: 16 * 1024 * 1024,
    });
    lastFetchHeaders = new Map();
    if (result.status !== 0 || !result.stdout) {
      lastFetchStatus = 0;
      return writeStr("");
    }
    const marker = result.stdout.lastIndexOf("\n__STATUS__");
    const withHeaders = marker < 0 ? result.stdout : result.stdout.substring(0, marker);
    lastFetchStatus = marker < 0
      ? 0
      : (parseInt(result.stdout.substring(marker + 11), 10) || 0);
    // With `-i`, curl may emit multiple header blocks (redirects,
    // 100-continue). Take the LAST one — its status matches
    // %{http_code}.
    const sepRe = /\r?\n\r?\n/g;
    let lastSep = -1;
    let lastHeaderStart = 0;
    let m;
    while ((m = sepRe.exec(withHeaders)) !== null) {
      if (withHeaders.substring(lastHeaderStart, m.index).match(/^HTTP\//)) {
        lastSep = m.index + m[0].length;
        lastHeaderStart = lastSep;
      } else {
        break;
      }
    }
    let bodyOut = withHeaders;
    let headerBlock = "";
    if (lastSep > 0) {
      const prevBlockEnd = withHeaders.lastIndexOf("\r\n\r\n", lastSep - 5);
      const blockStart = prevBlockEnd < 0 ? 0 : prevBlockEnd + 4;
      headerBlock = withHeaders.substring(blockStart, lastSep).replace(/\r?\n\r?\n$/, "");
      bodyOut = withHeaders.substring(lastSep);
    }
    const lines = headerBlock.split(/\r?\n/);
    for (let i = 1; i < lines.length; i++) {
      const colon = lines[i].indexOf(":");
      if (colon > 0) {
        const name = lines[i].substring(0, colon).trim().toLowerCase();
        const value = lines[i].substring(colon + 1).trim();
        lastFetchHeaders.set(name, value);
      }
    }
    return writeStr(bodyOut);
  };

  return {
    http_fetch,
    http_fetch_status: () => lastFetchStatus,
    http_fetch_add_header: (namePtr, valuePtr) => {
      nextFetchHeaders.push([readCStr(namePtr), readCStr(valuePtr)]);
      return 0;
    },
    http_fetch_response_header: (namePtr) => {
      const name = readCStr(namePtr).toLowerCase();
      return writeStr(lastFetchHeaders.get(name) || "");
    },
    http_fetch_set_timeout: (ms) => {
      nextFetchTimeoutMs = ms | 0;
      return 0;
    },
  };
}

module.exports = { makeHttpFetchEnv };

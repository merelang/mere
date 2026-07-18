// scripts/run_http_server.js — Node host for Mere HTTP servers.
//
// Merges the standard Wasm env imports (`puts`, libc stubs, etc.) with
// the `contrib/http` glue, instantiates the module, and calls `main()`.
// After `main()` returns the Node event loop keeps the process alive
// as long as the http server is bound.
//
// Usage: node scripts/run_http_server.js <path-to-wasm>

const fs = require("fs");
const path = require("path");
const { makeHttpGlue } = require("../contrib/http/http.glue.js");
const { makePgEnv } = require("./pg_env.js");
const { makeHttpFetchEnv } = require("./http_fetch_env.js");
const { makeSseRedisBridge } = require("./sse_redis_bridge.js");
const { makeSubprocessEnv } = require("./subprocess_env.js");

if (process.argv.length < 3) {
  console.error("usage: node run_http_server.js <path-to-wasm>");
  process.exit(2);
}
const wasmPath = process.argv[2];

(async () => {
  const wasmBytes = fs.readFileSync(wasmPath);
  let memory;

  const readCStr = (ptr) => {
    const bytes = new Uint8Array(memory.buffer);
    let end = ptr;
    while (end < bytes.length && bytes[end] !== 0) end++;
    return Buffer.from(bytes.subarray(ptr, end)).toString("utf8");
  };

  // Allocate on the shared Mere heap by advancing the `$__lang_bump`
  // global (exported from the Wasm module). This replaces the older
  // fixed 4KB scratch region (60K..64K), which was too small for
  // realistic extern returns — a multi-MB http_fetch body would
  // wrap the region and clobber the Mere heap sitting just above
  // it. Sharing the same bump pointer means Mere allocations and
  // extern-returned strings never collide.
  //
  // Memory is grown one 64KB page at a time when the current bump +
  // requested size exceeds the total buffer length.
  let langBump;  // set in bindMemory after instantiate
  const PAGE = 64 * 1024;
  const bumpAlloc = (n) => {
    const aligned = (n + 7) & ~7;
    const start = langBump.value;
    const needed = start + aligned;
    const capacity = memory.buffer.byteLength;
    if (needed > capacity) {
      const growPages = Math.ceil((needed - capacity) / PAGE);
      memory.grow(growPages);
    }
    langBump.value = start + aligned;
    return start;
  };

  // Copy a JS string into a fresh scratch slot and return the ptr.
  // Used by extern fns that need to hand a str back to Mere.
  const writeStr = (s) => {
    const utf8 = Buffer.from((s || "") + "\0", "utf8");
    const ptr = bumpAlloc(utf8.length);
    new Uint8Array(memory.buffer).set(utf8, ptr);
    return ptr;
  };

  const { glue: httpGlue, attach: attachHttp, broadcast } = makeHttpGlue();
  const fetchEnv = makeHttpFetchEnv({ readCStr, writeStr });
  const sseRedisBridge = makeSseRedisBridge({ broadcast, readCStr });
  const subprocessEnv = makeSubprocessEnv({ readCStr, writeStr });

  // Reuse the same set of env imports as scripts/run_wasm.js so any
  // extern fn a Mere program declares (getpid, sleep, str_of_float, …)
  // resolves. The http glue takes precedence for the http_serve name.
  const env = {
    puts: (ptr) => {
      process.stdout.write(readCStr(ptr) + "\n");
    },
    read_file: (pathPtr) => {
      const p = readCStr(pathPtr);
      try {
        const content = fs.readFileSync(p, "utf8");
        const bytes = Buffer.from(content + "\0", "utf8");
        const ptr = bumpAlloc(bytes.length);
        new Uint8Array(memory.buffer).set(bytes, ptr);
        return ptr;
      } catch (e) {
        console.error("read_file failed:", e.message);
        return 0;
      }
    },
    write_file: (pathPtr, contentPtr) => {
      const p = readCStr(pathPtr);
      const content = readCStr(contentPtr);
      try {
        fs.writeFileSync(p, content);
        return 0;
      } catch (e) {
        console.error("write_file failed:", e.message);
        return 1;
      }
    },
    __lang_str_of_float: (f) => {
      // v0.1.65: shortest round-trip formatting (12 digits first, widen
      // toward 17 until the string parses back to the same double) —
      // keep in lockstep with run_wasm.js and the interp / C / LLVM.
      let s;
      if (Number.isNaN(f)) s = "nan";
      else if (f === Infinity) s = "inf";
      else if (f === -Infinity) s = "-inf";
      else {
        for (let p = 12; ; p++) {
          s = f.toPrecision(p);
          if (s.includes("e") || s.includes("E")) {
            s = s.replace(/(\.\d*?)0+(e[+-]?\d+)/i, "$1$2").replace(/\.(e[+-]?\d+)/i, "$1");
          } else if (s.includes(".")) {
            s = s.replace(/\.?0+$/, "");
            if (s === "" || s === "-") s = "0";
          }
          if (p >= 17 || Number(s) === f) break;
        }
        if (!/[.eEni]/.test(s)) s += ".0";
      }
      const bytes = Buffer.from(s + "\0", "utf8");
      const ptr = bumpAlloc(bytes.length);
      new Uint8Array(memory.buffer).set(bytes, ptr);
      return ptr;
    },
    __lang_float_of_str: (ptr) => parseFloat(readCStr(ptr)),
    __lang_sin: Math.sin,
    __lang_cos: Math.cos,
    __lang_tan: Math.tan,
    __lang_f_pow: Math.pow,
    __lang_atan2: Math.atan2,
    getpid: () => process.pid,
    getppid: () => process.ppid,
    unix_time: () => Math.floor(Date.now() / 1000),
    // Monotonic milliseconds since process start, truncated to i32.
    // Uses performance.now() so subtracting two samples always gives
    // the correct elapsed even if the wall clock jumps. Stays in
    // i32 range for ~24 days of uptime — beyond that it wraps but
    // subtractions of nearby samples remain correct via i32
    // arithmetic overflow behaviour.
    now_ms: () => Math.floor(require("perf_hooks").performance.now()) | 0,
    rand: () => Math.floor(Math.random() * 0x7fffffff),
    srand: (_seed) => {},
    sleep: (_n) => 0,
    // sleep_ms(ms) — synchronous millisecond sleep via Atomics.wait
    // on a private SharedArrayBuffer. Blocks the whole Wasm frame,
    // so an HTTP server MUST NOT call this from inside a request
    // handler or the whole listener stalls. Fine in worker loops.
    sleep_ms: (ms) => {
      if (!ms || ms <= 0) return 0;
      const sab = new SharedArrayBuffer(4);
      Atomics.wait(new Int32Array(sab), 0, 0, ms);
      return 0;
    },
    abs_int: (n) => Math.abs(n | 0),
    getenv: (namePtr) => {
      const name = readCStr(namePtr);
      const v = process.env[name];
      if (v === undefined) return 0;
      const bytes = Buffer.from(v + "\0", "utf8");
      const ptr = bumpAlloc(bytes.length);
      new Uint8Array(memory.buffer).set(bytes, ptr);
      return ptr;
    },
    setenv: (namePtr, valuePtr, _overwrite) => {
      const name = readCStr(namePtr);
      const value = readCStr(valuePtr);
      process.env[name] = value;
      return 0;
    },
    system: (cmdPtr) => {
      const cmd = readCStr(cmdPtr);
      try {
        require("child_process").execSync(cmd, { stdio: "inherit" });
        return 0;
      } catch (e) {
        return e.status || 1;
      }
    },
    // sha256_hex : str -> str (64-char lowercase hex). Small, sync,
    // no dependencies beyond Node stdlib. Suitable for password
    // hashing in demos — real production should use a slow hash
    // (bcrypt / argon2) plus a per-user salt, both of which we can
    // layer on top once the extern fn exists.
    sha256_hex: (ptr) => {
      const s = readCStr(ptr);
      const hex = require("crypto").createHash("sha256").update(s).digest("hex");
      const bytes = Buffer.from(hex + "\0", "utf8");
      const outPtr = bumpAlloc(bytes.length);
      new Uint8Array(memory.buffer).set(bytes, outPtr);
      return outPtr;
    },
    // hmac_sha256_hex : str -> str -> str  (key, message → 64-char hex).
    // Wraps Node's `crypto.createHmac('sha256', key)` so Mere-side
    // webhook receivers can verify GitHub-style `X-Hub-Signature-256`
    // headers without reimplementing HMAC (which would need bytewise
    // XOR that the language doesn't currently expose).
    hmac_sha256_hex: (keyPtr, msgPtr) => {
      const key = readCStr(keyPtr);
      const msg = readCStr(msgPtr);
      const hex = require("crypto").createHmac("sha256", key)
        .update(msg).digest("hex");
      return writeStr(hex);
    },
    // base64url_encode / base64url_decode. RFC 4648 §5 base64url —
    // like base64 but replaces `+` / `/` with `-` / `_` and drops
    // trailing `=` padding. Needed for JWT (header / payload chunks +
    // HMAC signature). Bit-level ops in pure Mere are awkward without
    // shift/and primitives, so we hand off to Node's Buffer here.
    base64url_encode: (ptr) => {
      const s = readCStr(ptr);
      const b = Buffer.from(s, "utf8").toString("base64url");
      return writeStr(b);
    },
    base64url_decode: (ptr) => {
      const s = readCStr(ptr);
      try {
        const b = Buffer.from(s, "base64url").toString("utf8");
        return writeStr(b);
      } catch (e) {
        return writeStr("");
      }
    },
    // HMAC-SHA256 → base64url. Convenience wrapper so JWT signing
    // doesn't have to do `hmac_sha256_hex` then hex→bytes→base64url
    // (which requires the same bit-shift plumbing that keeps us
    // externing base64 in the first place).
    hmac_sha256_base64url: (keyPtr, msgPtr) => {
      const key = readCStr(keyPtr);
      const msg = readCStr(msgPtr);
      const b = require("crypto").createHmac("sha256", key)
        .update(msg).digest("base64url");
      return writeStr(b);
    },
    // gen_request_id — now provided by pg_env (shared with run_wasm.js
    // so CLI Mere programs that use it, e.g. contrib/db/redis_lock's
    // fencing tokens, link cleanly under either runner).
    // Outbound HTTP externs (http_fetch, http_fetch_status, and the
    // header / timeout controls) are provided by http_fetch_env so
    // run_wasm.js can offer the same capability. See its module
    // header for the extern signatures.
    ...fetchEnv,
    ...sseRedisBridge,
    ...subprocessEnv,
    ...httpGlue,
  };

  // Merge the shared pg env (TCP sync + byte-buffer primitives + crypto).
  // Uses the same bumpAlloc so extern-returned strings live on the Mere
  // heap. pg_env's crypto entries (sha256_hex / hmac_sha256_hex / …)
  // OVERWRITE the http-server's existing versions, but the implementations
  // are byte-for-byte identical so the behavior stays the same.
  Object.assign(env, makePgEnv({
    getMemory: () => memory.buffer,
    bumpAlloc: (n) => bumpAlloc(n),
  }));

  const { instance } = await WebAssembly.instantiate(wasmBytes, { env });
  memory = instance.exports.memory;
  langBump = instance.exports.__lang_bump;
  if (!langBump) {
    throw new Error(
      "wasm module does not export __lang_bump — rebuild with a codegen " +
      "that exports it (needed so extern-returned strings and Mere " +
      "allocations share a bump pointer)."
    );
  }
  attachHttp(instance);

  try {
    instance.exports.main();
  } catch (e) {
    if (e instanceof WebAssembly.RuntimeError) {
      process.exit(1);
    } else {
      throw e;
    }
  }
})().catch((e) => {
  console.error("error:", e);
  process.exit(1);
});

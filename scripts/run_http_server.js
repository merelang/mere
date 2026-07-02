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

  let scratchOffset = 56 * 1024;
  const bumpAlloc = (n) => {
    const ptr = scratchOffset;
    scratchOffset += (n + 7) & ~7;
    return ptr;
  };

  // Copy a JS string into a fresh scratch slot and return the ptr.
  // Used by extern fns that need to hand a str back to Mere.
  const writeStr = (s) => {
    const utf8 = Buffer.from((s || "") + "\0", "utf8");
    const ptr = bumpAlloc(utf8.length);
    new Uint8Array(memory.buffer).set(utf8, ptr);
    return ptr;
  };

  // Slot for `http_fetch_status ()` — the HTTP status code of the
  // last `http_fetch` call. Reset per request implicitly by the
  // extern fn on entry.
  let lastFetchStatus = 0;

  const { glue: httpGlue, attach: attachHttp } = makeHttpGlue();

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
      let s;
      if (Number.isNaN(f)) s = "nan";
      else if (f === Infinity) s = "inf";
      else if (f === -Infinity) s = "-inf";
      else {
        s = f.toPrecision(12);
        if (s.includes("e") || s.includes("E")) {
          s = s.replace(/(\.\d*?)0+(e[+-]?\d+)/i, "$1$2").replace(/\.(e[+-]?\d+)/i, "$1");
        } else if (s.includes(".")) {
          s = s.replace(/\.?0+$/, "");
          if (s === "" || s === "-") s = "0";
        }
        if (!/[.eEni]/.test(s)) s += ".";
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
    rand: () => Math.floor(Math.random() * 0x7fffffff),
    srand: (_seed) => {},
    sleep: (_n) => 0,
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
    // http_fetch : str -> str -> str -> str  (method, url, body → body)
    // Synchronous outbound HTTP via `curl` (spawnSync). Body is sent
    // verbatim as `--data-binary` when non-empty. Status code is
    // stashed on `lastFetchStatus` (read via `http_fetch_status ()`).
    // Empty return on network error or non-zero curl exit; caller
    // should check status when it matters.
    //
    // Depends on `curl` being on PATH (macOS / Linux default, most
    // Docker base images have it). Production would use a proper
    // Node http client with async event-loop integration, but the
    // wasm-called-from-JS execution model forces sync here.
    http_fetch: (methodPtr, urlPtr, bodyPtr) => {
      const method = readCStr(methodPtr) || "GET";
      const url = readCStr(urlPtr);
      const body = readCStr(bodyPtr);
      const { spawnSync } = require("child_process");
      const args = ["-sS", "-w", "\n__STATUS__%{http_code}", "-X", method];
      if (body && body.length > 0) args.push("--data-binary", body);
      args.push(url);
      const result = spawnSync("curl", args, {
        encoding: "utf8",
        timeout: 10000,
        maxBuffer: 16 * 1024 * 1024,
      });
      if (result.status !== 0 || !result.stdout) {
        lastFetchStatus = 0;
        return writeStr("");
      }
      const marker = result.stdout.lastIndexOf("\n__STATUS__");
      if (marker < 0) {
        lastFetchStatus = 0;
        return writeStr(result.stdout);
      }
      lastFetchStatus = parseInt(result.stdout.substring(marker + 11), 10) || 0;
      return writeStr(result.stdout.substring(0, marker));
    },
    http_fetch_status: () => lastFetchStatus,
    ...httpGlue,
  };

  const { instance } = await WebAssembly.instantiate(wasmBytes, { env });
  memory = instance.exports.memory;
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

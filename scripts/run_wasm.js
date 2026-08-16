// Phase 27.2: Wasm runtime host harness for Mere examples.
// Loads a .wasm file, provides env imports (puts, read_file, write_file),
// invokes main, and captures puts output.
//
// Usage: node run_wasm.js <path-to-wasm>

const fs = require('fs');
const { checkAbi, makeMarshal } = require("./mere_host.js");

function mereParseFloat(raw) {
  const s = raw.trim().split("_").join("");
  if (s === "") return { ok: false, value: 0 };
  const m = /^([+-]?)(inf(inity)?|nan)$/i.exec(s);
  if (m) {
    if (/^nan$/i.test(m[2])) return { ok: true, value: NaN };
    return { ok: true, value: m[1] === "-" ? -Infinity : Infinity };
  }
  // hex floats: 0x1p3 is 8, and JS has no literal for them
  const h = /^([+-]?)0[xX]([0-9a-fA-F]*)(?:\.([0-9a-fA-F]*))?(?:[pP]([+-]?\d+))?$/.exec(s);
  if (h) {
    if (!h[2] && !h[3]) return { ok: false, value: 0 };
    let v = 0;
    for (const c of h[2] || "") v = v * 16 + parseInt(c, 16);
    let scale = 1 / 16;
    for (const c of h[3] || "") { v += parseInt(c, 16) * scale; scale /= 16; }
    if (h[4] !== undefined) v *= Math.pow(2, parseInt(h[4], 10));
    return { ok: true, value: h[1] === "-" ? -v : v };
  }
  if (!/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(s)) return { ok: false, value: 0 };
  const v = Number(s);
  return Number.isNaN(v) ? { ok: false, value: 0 } : { ok: true, value: v };
}

const { Worker } = require('worker_threads');
const { makePgEnv } = require('./pg_env.js');
const { makeHttpFetchEnv } = require('./http_fetch_env.js');
const { makeSubprocessEnv } = require('./subprocess_env.js');

// Q-012: channel host ops over the SHARED wasm memory. A channel is a small
// region of shared linear memory (allocated by the creating instance's bump
// allocator); every instance's host import reads/writes it with JS Atomics,
// so the queue is coherent across worker threads. Layout in i32 words at
// `ptr`: [0]=mutex, [1]=count, [2]=head, [3]=cap, [4..]=ring buffer.
// Defined as a named function so its source can be injected into the worker
// bootstrap verbatim (workers need the same channel ops).
function makeChannelEnv(getBuffer, bumpAlloc) {
  // v0.1.127 (i64 value model): channel VALUES are 64-bit. Layout at `ptr`
  // (8-byte aligned): i32 header words [0]=mutex, [1]=count, [2]=head,
  // [3]=cap, then a ring of CAP BigInt64 slots starting at byte ptr+16.
  const CAP = 4096;
  const lock = (i32, p) => {
    while (Atomics.compareExchange(i32, p, 0, 1) !== 0) Atomics.wait(i32, p, 1);
  };
  const unlock = (i32, p) => { Atomics.store(i32, p, 0); Atomics.notify(i32, p, 1); };
  return {
    mere_channel_new: (_unit) => {
      const raw = bumpAlloc(16 + CAP * 8 + 8);
      const ptr = (raw + 7) & ~7;  // 8-byte align for the BigInt64 ring
      const i32 = new Int32Array(getBuffer());
      const p = ptr >> 2;
      i32[p] = 0; i32[p + 1] = 0; i32[p + 2] = 0; i32[p + 3] = CAP;
      return ptr;
    },
    mere_channel_send: (ptr, v) => {
      const i32 = new Int32Array(getBuffer());
      const ring = new BigInt64Array(getBuffer(), ptr + 16, CAP);
      const p = ptr >> 2;
      lock(i32, p);
      const count = i32[p + 1], cap = i32[p + 3], head = i32[p + 2];
      ring[(head + count) % cap] = BigInt(v);
      Atomics.store(i32, p + 1, count + 1);
      unlock(i32, p);
      Atomics.notify(i32, p + 1);  // wake recv waiters blocked on count
      return 0;
    },
    mere_channel_recv: (ptr) => {
      const i32 = new Int32Array(getBuffer());
      const ring = new BigInt64Array(getBuffer(), ptr + 16, CAP);
      const p = ptr >> 2;
      for (;;) {
        lock(i32, p);
        const count = i32[p + 1];
        if (count > 0) {
          const head = i32[p + 2], cap = i32[p + 3];
          const v = ring[head];
          Atomics.store(i32, p + 2, (head + 1) % cap);
          Atomics.store(i32, p + 1, count - 1);
          unlock(i32, p);
          return v;
        }
        unlock(i32, p);
        Atomics.wait(i32, p + 1, 0);  // block while empty
      }
    },
  };
}

// Q-012: worker bootstrap for spawn. A spawned worker instantiates the SAME
// wasm module over the SAME shared memory (so the closure's env offset and
// the function-table index are both valid), then invokes the closure via the
// indirect function table: table.get(fnIdx)(envOffset, 0). It signals
// completion by setting a shared flag that mere_join waits on. Channel ops
// operate on the shared memory (makeChannelEnv, injected below). This MVP
// supports non-allocating worker closures (the bump allocator is per-instance;
// a shared allocator is a follow-up), which covers int-channel compute.
const WORKER_CODE = `
const { workerData } = require('worker_threads');
const { wasmBytes, memory, fnIdx, envOff, doneSab, bumpBase } = workerData;
const readCStr = (ptr) => {
  const bytes = new Uint8Array(memory.buffer);
  let end = ptr; while (end < bytes.length && bytes[end] !== 0) end++;
  return Buffer.from(bytes.subarray(ptr, end)).toString('utf8');
};
// A str's length is in its header (ptr-4), so a zero byte inside it is a
// byte and not an end. print writes the whole value on the interpreter
// and on C; scanning for a NUL here made the Wasm build print less.
const readStrBytes = (ptr) => {
  if (!ptr) return Buffer.alloc(0);
  const len = new DataView(memory.buffer).getInt32(ptr - 4, true);
  if (len < 0 || ptr + len > memory.buffer.byteLength) return Buffer.alloc(0);
  return Buffer.from(new Uint8Array(memory.buffer).subarray(ptr, ptr + len));
};
${makeChannelEnv.toString()}
const stub = () => 0;
const env = Object.assign({
  memory,
  puts: (ptr) => { process.stdout.write(readStrBytes(ptr)); process.stdout.write('\\n'); },
  print_no_nl: (ptr) => process.stdout.write(readStrBytes(ptr)),
  // A pointer and a length: a zero is a byte, not an end.
  print_bytes: (ptr, len) =>
    process.stdout.write(Buffer.from(memory.buffer, ptr, len)),
  time: () => Date.now() / 1000,
  mere_spawn: stub, mere_join: stub,
  __lang_str_of_float: stub, __lang_float_of_str: stub,
  // v0.1.277: the worker instantiates the SAME module, so every import the
  // module declares has to exist here too -- a missing one makes instantiation
  // throw inside the worker, and the main thread then waits on a generator that
  // will never yield. It cost twenty minutes of a hung parity run to notice.
  __lang_float_of_str_ok: stub,
  __lang_sin: Math.sin, __lang_cos: Math.cos, __lang_tan: Math.tan, __lang_exp: Math.exp, __lang_log: Math.log,
  __lang_f_pow: Math.pow, __lang_atan2: Math.atan2,
}, makeChannelEnv(() => memory.buffer, () => { throw new Error('no alloc in spawned worker'); }));

(async () => {
  const { instance } = await WebAssembly.instantiate(wasmBytes, { env });
  // Point this worker's bump allocator at its private region so allocations
  // in the spawned closure don't collide with other workers or the parent.
  if (instance.exports.__lang_bump) instance.exports.__lang_bump.value = bumpBase;
  const table = instance.exports.__indirect_function_table;
  try { table.get(fnIdx)(BigInt(envOff), 0n); } catch (e) { /* wasm trap in child */ }
  Atomics.store(new Int32Array(doneSab), 0, 1);
  Atomics.notify(new Int32Array(doneSab), 0);
})();
`;

if (process.argv.length < 3) {
  console.error("usage: node run_wasm.js <path-to-wasm>");
  process.exit(2);
}
const wasmPath = process.argv[2];

(async () => {
  const wasmBytes = fs.readFileSync(wasmPath);
  let memory; // captured after instantiate

  // Read a C-style null-terminated string from linear memory at offset.
  // Boundary helpers come from scripts/mere_host.js. This runner used to
  // open-code the str layout at four call sites and keep a fifth copy in
  // a shared helper — the reason the length header landed here and in no
  // other host.
  let langBump = null;  // set after instantiate
  const { bumpAlloc, writeStr, writeBytes, readCStr, readStrBytes } = makeMarshal({
    getMemory: () => memory,
    getBump: () => langBump,
  });

  // Open file descriptors for positioned I/O, indexed by the handle value
  // Mere sees. Slot 0 is reserved as a null sentinel.
  const openFiles = [undefined];

  const env = {
    puts: (ptr) => {
      // By LENGTH, not up to the first NUL: a str carries its length in the
      // header, `str_len` answers with it, and printing less than that is
      // two answers about one value. The newline matches C's puts.
      process.stdout.write(readStrBytes(ptr));
      process.stdout.write("\n");
    },
    read_file: (pathPtr) => {
      const path = readCStr(pathPtr);
      try {
        const content = fs.readFileSync(path, "utf8");
        return writeStr(content);
      } catch (e) {
        // A missing file is an expected probe result (the module-path
        // resolver walks up testing for mere.toml; the language-level
        // read_file fails catchably) — return 0 silently. Log anything else.
        if (e.code !== "ENOENT") console.error("read_file failed:", e.message);
        return 0;
      }
    },
    write_file: (pathPtr, contentPtr) => {
      const path = readCStr(pathPtr);
      const content = readCStr(contentPtr);
      try {
        fs.writeFileSync(path, content);
        return 0;
      } catch (e) {
        console.error("write_file failed:", e.message);
        return 1;
      }
    },
    // Binary file I/O. read_file_bytes returns a pointer to a length-prefixed
    // buffer [i32 len][raw bytes...] (the mere_bytes layout); the Wasm side
    // turns it into a Vec[int] via the bytes bridge. On a missing file it
    // returns an empty buffer (len 0). write_file_bytes reads the same layout.
    read_file_bytes: (pathPtr) => {
      const path = readCStr(pathPtr);
      let buf;
      try {
        buf = fs.readFileSync(path);
      } catch (e) {
        if (e.code !== "ENOENT") console.error("read_file_bytes failed:", e.message);
        buf = Buffer.alloc(0);
      }
      return writeBytes(buf);
    },
    // Positioned file I/O on an open handle (v0.1.153) — what a paged
    // store needs, since read/write_file_bytes only replace a whole file.
    // The Mere-side value is an index into `openFiles`; the host owns the
    // descriptor, exactly as the browser host will own an OPFS access
    // handle. Handle 0 is a null sentinel so a failed open is falsy.
    file_openrw: (pathPtr) => {
      const path = readCStr(pathPtr);
      try {
        // "r+" then "w+": create if absent, never truncate an existing file.
        let fd;
        try { fd = fs.openSync(path, "r+"); }
        catch (e) { fd = fs.openSync(path, "w+"); }
        openFiles.push(fd);
        return openFiles.length - 1;
      } catch (e) {
        console.error("file_openrw failed:", e.message);
        return 0;
      }
    },
    // Returns a mere_bytes buffer [i32 len][raw bytes] on the Mere heap;
    // the Wasm side converts it to Vec[int]. A short read (past EOF) comes
    // back as a shorter buffer, matching the C runtime's fgetc loop.
    file_pread: (handle, off, len) => {
      const fd = openFiles[handle];
      const buf = Buffer.alloc(Math.max(0, len));
      let got = 0;
      if (fd !== undefined && len > 0 && off >= 0) {
        try { got = fs.readSync(fd, buf, 0, len, off); } catch (e) { got = 0; }
      }
      return writeBytes(buf.subarray(0, got));
    },
    file_pwrite: (handle, off, bytesPtr) => {
      const fd = openFiles[handle];
      if (fd === undefined || off < 0) return 0;
      const len = new DataView(memory.buffer).getInt32(bytesPtr, true);
      const mem = new Uint8Array(memory.buffer);
      const src = Buffer.from(mem.subarray(bytesPtr + 4, bytesPtr + 4 + len));
      try { return fs.writeSync(fd, src, 0, len, off); } catch (e) { return 0; }
    },
    file_fsync: (handle) => {
      const fd = openFiles[handle];
      if (fd !== undefined) { try { fs.fsyncSync(fd); } catch (e) { /* ignore */ } }
      return 0;
    },
    // Size by path, so an append-only store can find its end without
    // reading the file to measure it.
    file_size: (pathPtr) => {
      try { return fs.statSync(readCStr(pathPtr)).size; } catch (e) { return 0; }
    },
    file_close: (handle) => {
      const fd = openFiles[handle];
      if (fd !== undefined) {
        try { fs.closeSync(fd); } catch (e) { /* ignore */ }
        openFiles[handle] = undefined;
      }
      return 0;
    },
    write_file_bytes: (pathPtr, bytesPtr) => {
      const path = readCStr(pathPtr);
      try {
        const dv = new DataView(memory.buffer);
        const len = dv.getInt32(bytesPtr, true);
        const mem = new Uint8Array(memory.buffer);
        fs.writeFileSync(path, Buffer.from(mem.subarray(bytesPtr + 4, bytesPtr + 4 + len)));
        return 0;
      } catch (e) {
        console.error("write_file_bytes failed:", e.message);
        return 1;
      }
    },
    // Phase 34.3 (Wasm float): str_of_float / float_of_str host imports.
    // v0.1.65: shortest ROUND-TRIP formatting, matching the interp / C /
    // LLVM helpers. Try 12 significant digits first (the historical
    // format — unchanged output where it was already faithful), then
    // widen toward 17 until the string parses back to the same double.
    __lang_str_of_float: (f) => {
      let s;
      if (Number.isNaN(f)) s = "nan";
      else if (f === Infinity) s = "inf";
      else if (f === -Infinity) s = "-inf";
      else {
        for (let p = 12; ; p++) {
          // C's %g, which is what the other three backends print through: with
          // P significant digits and X the decimal exponent, use %e when
          // X < -4 or X >= P and %f otherwise, then strip trailing zeros.
          // `toPrecision` is NOT that rule — it stays decimal down to 1e-7 — so
          // exp -10 printed as 0.00004539992976248485 here and as
          // 4.5399929762484854e-05 on the other three. The exponent comes from
          // toExponential rather than log10, which is off by one at a power of
          // ten.
          const es = f.toExponential(p - 1);
          const x = parseInt(es.slice(es.indexOf("e") + 1), 10);
          if (x < -4 || x >= p) {
            let m = es.slice(0, es.indexOf("e"));
            if (m.includes(".")) m = m.replace(/0+$/, "").replace(/\.$/, "");
            const e = es.slice(es.indexOf("e") + 1);
            const sign = e[0] === "-" ? "-" : "+";
            // C pads the exponent to at least two digits; JS does not.
            const digits = e.replace(/^[+-]/, "").padStart(2, "0");
            s = m + "e" + sign + digits;
          } else {
            s = f.toFixed(Math.max(0, p - 1 - x));
            if (s.includes(".")) s = s.replace(/0+$/, "").replace(/\.$/, "");
            if (s === "" || s === "-") s = "0";
          }
          if (p >= 17 || Number(s) === f) break;
        }
        // OCaml: append ".0" for plain integer-valued floats
        if (!/[.eEni]/.test(s)) s += ".0";
      }
      return writeStr(s);
    },
    // v0.1.277: parseFloat is not this language's float syntax. It reads a
    // PREFIX (so "1.5x" was 1.5 and "1_000.5" was 1.0), does not know
    // "inf"/"infinity" or hex floats (both nan / 0 here, both real values
    // everywhere else), and answers NaN for a string that is not a float at all
    // -- which is indistinguishable from the float `nan`, so nothing could be
    // refused. The rule below is the interpreter's: trim, drop the underscores
    // OCaml allows as separators, then accept only if the whole of what is left
    // is a float. Validity is reported through a second import, because one
    // return value cannot say both "nan" and "not a number at all".
    __lang_float_of_str: (ptr) => mereParseFloat(readCStr(ptr)).value,
    __lang_float_of_str_ok: (ptr) => (mereParseFloat(readCStr(ptr)).ok ? 1 : 0),
    // v0.1.127: wall clock for the `time` builtin (epoch seconds, f64).
    time: () => Date.now() / 1000,
    // print without the trailing newline (Mere's print_no_nl builtin), by
    // length for the same reason as puts.
    print_no_nl: (ptr) => process.stdout.write(readStrBytes(ptr)),
    // print_bytes takes a pointer *and a length*, which is the whole reason
    // it exists: a byte sequence is exactly what a NUL-terminated string
    // cannot carry, because a zero is a byte and not an end.
    print_bytes: (ptr, len) =>
      process.stdout.write(Buffer.from(memory.buffer, ptr, len)),
    // Phase 34.4: libm functions (anything not in Wasm intrinsics is provided by the host)
    __lang_sin: Math.sin,
    __lang_cos: Math.cos,
    __lang_tan: Math.tan, __lang_exp: Math.exp, __lang_log: Math.log,
    __lang_f_pow: Math.pow,
    __lang_atan2: Math.atan2,
    // Phase 32.4 (C1 FFI): default impls for common libc functions that
    // Mere programs declare via `extern fn`. Add more as needed.
    getpid: () => process.pid,
    getppid: () => process.ppid,
    unix_time: () => Math.floor(Date.now() / 1000),
    // Monotonic milliseconds since process start, truncated to i32.
    // Same shape as run_http_server.js so contrib modules that pull
    // `now_ms` (e.g. metrics duration counters) work under either
    // runner.
    now_ms: () => Math.floor(require("perf_hooks").performance.now()) | 0,
    rand: () => Math.floor(Math.random() * 0x7fffffff),
    srand: (_seed) => {},  // JS Math.random can't be seeded; no-op
    sleep: (_n) => 0,       // skip blocking sleep in JS context
    // sleep_ms(ms) — synchronous millisecond sleep via Atomics.wait
    // on a private SharedArrayBuffer. Blocks the whole Wasm frame
    // (which is what Mere programs want when they call it), so this
    // is only useful for CLIs / worker loops that WANT to pause; a
    // web server should not call it or all requests will stall.
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
      if (v === undefined) return 0;  // NULL — Mere expects str, segfault risk
      // byte-safe str layout: [i32 len][bytes][NUL]; return byte0 (ptr+4).
      const body = Buffer.from(v);
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
    // arg_count / arg_get — user-facing CLI args (everything after the
    // .wasm path on the command line). Same as `argv[1:]` in a normal
    // program: `node run_wasm.js foo.wasm --flag path/to/input` gives
    // arg_count() = 2, arg_get(0) = "--flag", arg_get(1) = "path/…".
    // Needed for self-hosted CLI tools (mere-in-Mere compiler driver
    // that takes an input file path).
    arg_count: () => process.argv.length - 3,
    arg_get: (n) => {
      const args = process.argv.slice(3);
      const v = args[n | 0] || "";
        return writeStr(v);
    },
    // TCP + byte-buffer + crypto externs come from the shared pg_env
    // module; they're merged into `env` below with Object.assign.
  };
  Object.assign(env, makePgEnv({
    getMemory: () => memory.buffer,
    bumpAlloc: (n) => bumpAlloc(n),
  }));
  // Outbound HTTP (http_fetch and friends) — same curl-based
  // implementation as run_http_server.js. Any Mere CLI that declares
  // `extern fn http_fetch: ...` can now make outbound calls too.
  Object.assign(env, makeHttpFetchEnv({ readCStr, writeStr }));
  Object.assign(env, makeSubprocessEnv({ readCStr, writeStr }));


  // Q-012: if the module imports a shared memory (a threaded program), the
  // host must create it so every worker instance shares one memory. Detect
  // that from the module's import list and wire spawn/join.
  const wasmModule = new WebAssembly.Module(wasmBytes);
  const moduleImports = WebAssembly.Module.imports(wasmModule);
  const needsSharedMem = moduleImports.some(
    (i) => i.module === 'env' && i.name === 'memory' && i.kind === 'memory');
  let sharedMemory = null;
  if (needsSharedMem) {
    sharedMemory = new WebAssembly.Memory({ initial: 1024, maximum: 65536, shared: true });
    env.memory = sharedMemory;
    let nextTid = 1;
    const threads = new Map();
    env.mere_spawn = (closurePtr) => {
      const view = new DataView(sharedMemory.buffer);
      const envOff = view.getInt32(closurePtr, true);
      const fnIdx = view.getInt32(closurePtr + 4, true);
      const tid = nextTid++;
      const doneSab = new SharedArrayBuffer(4);
      // Each worker allocates from a disjoint bump region so concurrent
      // allocations can't collide (the bump pointer is a per-instance global).
      // This is the pragmatic alternative to a single shared atomic bump:
      // the main instance uses the low region, worker i uses [16MB + i*8MB, …).
      const bumpBase = 16 * 1024 * 1024 + (tid - 1) * 8 * 1024 * 1024;
      const worker = new Worker(WORKER_CODE, {
        eval: true,
        workerData: { wasmBytes, memory: sharedMemory, fnIdx, envOff, doneSab, bumpBase },
      });
      worker.on('error', (e) => console.error('worker error:', e));
      threads.set(tid, { worker, done: new Int32Array(doneSab) });
      return tid;
    };
    env.mere_join = (tid) => {
      const t = threads.get(tid);
      if (t) { Atomics.wait(t.done, 0, 0); t.worker.terminate(); }
      return 0;
    };
    // Channels live in the shared memory; the creating (main) instance
    // allocates via its bump allocator, workers just read/write.
    Object.assign(env, makeChannelEnv(() => sharedMemory.buffer, bumpAlloc));
  }

  // instantiate(Module, imports) resolves to the Instance directly (unlike
  // instantiate(bytes, imports) which resolves to { instance, module }).
  const instance = await WebAssembly.instantiate(wasmModule, { env });
  checkAbi(instance, "scripts/run_wasm.js");
  memory = needsSharedMem ? sharedMemory : instance.exports.memory;
  langBump = instance.exports.__lang_bump || null;

  // Phase 48.2 (C2 Stage 2): helper for invoking a Mere closure value
  // (an i32 pointer to a 2-word { env, fn_idx } record in linear memory)
  // from JS. Hosts that wire `extern fn ... -> (T -> U) -> ...` should
  // hold onto the closure pointer the Wasm code passes, then use this
  // helper from event callbacks etc.
  //
  // Usage from a host import:
  //   env.dom_on_click = (btnPtr, closurePtr) => {
  //     document.getElementById(...).addEventListener('click', () =>
  //       callMereClosure(closurePtr, /* arg */ 0));
  //   };
  const table = instance.exports.__indirect_function_table;
  const callMereClosure = (closurePtr, arg = 0) => {
    if (!table) throw new Error("Wasm module did not export __indirect_function_table");
    // Mere's bump allocator does not enforce 4-byte alignment, so the
    // closure record's offset may be misaligned. Int32Array indexing
    // rounds the byte offset to a 4-byte boundary; DataView accepts any.
    // v0.1.127: the closure type is (param i64 i64) (result i64) — args
    // cross as BigInt.
    const view = new DataView(memory.buffer);
    const env = view.getInt32(closurePtr, true);
    const fnIdx = view.getInt32(closurePtr + 4, true);
    return table.get(fnIdx)(BigInt(env), BigInt(arg));
  };
  // Expose for hosts that bind extra env imports later (e.g. DOM glue).
  globalThis.__mere_call_closure = callMereClosure;

  try {
    instance.exports.main();
  } catch (e) {
    if (e instanceof RangeError) {
      // v0.1.271: the host's own words for this are "Maximum call stack size
      // exceeded", with a stack trace of the same wasm frame a few hundred
      // times. Say what the other three backends say instead -- the failure is
      // the same one, and a program should not be diagnosed differently
      // depending on which backend it was run through.
      // stdout, because that is the one sink this host's diagnostics use
      // (env.puts writes there, and scripts/parity.sh pins the fact).
      process.stdout.write("stack overflow (recursion too deep)\n");
      process.exit(1);
    }
    if (e instanceof WebAssembly.RuntimeError) {
      // Wasm trap. `fail` is the expected one: it prints via puts and THEN
      // executes unreachable, so its message is already out and this handler
      // has nothing to add.
      //
      // v0.1.274: every other trap used to exit here in silence. The one a
      // Mere program reaches by ordinary means is running out of memory --
      // this backend's memory is a fixed 64MB and nothing grows it, so an
      // allocation past the end is an out-of-bounds store -- and it exited 1
      // with no output at all, where the C and LLVM backends now name it.
      // Any other trap says what the engine called it rather than nothing.
      const msg = String(e.message || "");
      if (/out of bounds/i.test(msg)) {
        process.stdout.write("out of memory\n");
      } else if (!/unreachable/i.test(msg)) {
        process.stdout.write("trap: " + msg + "\n");
      }
      process.exit(1);
    } else {
      throw e;
    }
  }
})().catch((e) => {
  console.error("error:", e);
  process.exit(1);
});

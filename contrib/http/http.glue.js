// contrib/http/http.glue.js — Node host glue for `contrib/http/http.mere`.
//
// Wires the single `extern fn http_serve` to a Node `http.createServer`
// instance. Each incoming request is dispatched to the Mere-supplied
// closure; the returned string is sent back as the response body.
//
// Usage pattern mirrors contrib/dom:
//
//   const { makeHttpGlue } = require("./contrib/http/http.glue.js");
//   const { glue, attach } = makeHttpGlue();
//   const { instance } = await WebAssembly.instantiate(wasmBytes, {
//     env: { ...glue, /* puts, math, ... */ }
//   });
//   attach(instance);
//   instance.exports.main();
//
// The `glue` object is passed to `instantiate` *before* the instance
// exists; `attach(instance)` then hands the instance's memory + table
// to the closure so the http import can start firing.

function makeHttpGlue() {
  let memory = null;
  let table = null;

  const readCStr = (ptr) => {
    if (!memory) return "";
    const bytes = new Uint8Array(memory.buffer);
    let end = ptr;
    while (end < bytes.length && bytes[end] !== 0) end++;
    return Buffer.from(bytes.subarray(ptr, end)).toString("utf8");
  };

  // Scratch buffer for handing request strings back to Mere. Sits high
  // in memory to avoid trampling the bump arena; each in-flight request
  // gets its own slice, and the offset resets between requests. The
  // Mere handler is called synchronously within the request callback,
  // so a single-buffer design is safe.
  let scratchOffset = 56 * 1024;
  const SCRATCH_LIMIT = 60 * 1024;

  const writeStr = (s) => {
    if (!memory) return 0;
    const utf8 = Buffer.from(s, "utf8");
    const total = utf8.length + 1;
    if (scratchOffset + total > SCRATCH_LIMIT) {
      scratchOffset = 56 * 1024;
    }
    const ptr = scratchOffset;
    new Uint8Array(memory.buffer).set(utf8, ptr);
    new Uint8Array(memory.buffer)[ptr + utf8.length] = 0;
    scratchOffset += total;
    return ptr;
  };

  const callClosure = (closurePtr, argPtr) => {
    if (!memory || !table) {
      console.error("contrib/http: callClosure invoked before attach()");
      return 0;
    }
    // Mere's bump allocator does not enforce 4-byte alignment, so use
    // DataView (which accepts any byte offset) rather than Int32Array.
    const view = new DataView(memory.buffer);
    const env = view.getInt32(closurePtr, true);
    const fnIdx = view.getInt32(closurePtr + 4, true);
    const fn = table.get(fnIdx);
    if (typeof fn !== "function") {
      console.error("contrib/http: closure fn_idx not in table", { closurePtr, env, fnIdx });
      return 0;
    }
    return fn(env, argPtr);
  };

  // Per-request slots. `http_serve` populates the body pointer + resets
  // status / content-type / extra headers to defaults before dispatch;
  // the handler may read the body and override status / content-type /
  // custom headers. A single slot is enough because the Wasm-side
  // handler runs entirely within one JS turn.
  let currentBodyPtr = 0;
  let currentStatus = 200;
  let currentContentType = "text/plain; charset=utf-8";
  let currentHeaders = {};
  // Request-side headers, populated per request from `req.headers`
  // (already lowercase-keyed by Node). Read via `http_get_header name`
  // (case-insensitive lookup — we lowercase the name before indexing).
  let currentReqHeaders = {};

  const glue = {
    http_serve: (port, closurePtr) => {
      const http = require("http");
      const server = http.createServer((req, res) => {
        // Reset scratch + response defaults per request so nothing bleeds.
        scratchOffset = 56 * 1024;
        currentStatus = 200;
        currentContentType = "text/plain; charset=utf-8";
        currentHeaders = {};
        currentReqHeaders = req.headers || {};
        const chunks = [];
        req.on("data", (c) => chunks.push(c));
        req.on("end", () => {
          const body = Buffer.concat(chunks).toString("utf8");
          currentBodyPtr = writeStr(body);
          const reqLine = req.method + " " + req.url;
          const reqPtr = writeStr(reqLine);
          const respPtr = callClosure(closurePtr, reqPtr);
          const respBody = readCStr(respPtr);
          currentBodyPtr = 0;
          const headers = { ...currentHeaders, "Content-Type": currentContentType };
          res.writeHead(currentStatus, headers);
          res.end(respBody);
        });
      });
      server.on("error", (e) => {
        console.error("contrib/http: server error:", e.message);
      });
      server.listen(port, () => {
        console.log(`contrib/http: listening on :${port}`);
      });
    },
    http_current_body: () => currentBodyPtr,
    http_set_status: (code) => { currentStatus = code | 0; },
    http_set_content_type: (ptr) => { currentContentType = readCStr(ptr); },
    http_set_header: (namePtr, valuePtr) => {
      currentHeaders[readCStr(namePtr)] = readCStr(valuePtr);
    },
    // Read a request header by name (case-insensitive). Returns a
    // pointer to a NUL-terminated str with the value, or empty string
    // if the header wasn't set. Node normalizes header keys to
    // lowercase, so we lowercase the name before indexing. Multi-value
    // headers (Set-Cookie / etc.) join on ", " by default from Node —
    // callers wanting individual values need to split.
    http_get_header: (namePtr) => {
      const name = readCStr(namePtr).toLowerCase();
      const val = currentReqHeaders[name];
      if (val === undefined || val === null) return writeStr("");
      if (Array.isArray(val)) return writeStr(val.join(", "));
      return writeStr(String(val));
    },
    // Read the current response status code (as set by
    // `http_set_status` earlier in the same handler, or 200 by
    // default). Useful for access-log middleware that wants to
    // record the outcome after the inner handler runs.
    http_current_status: () => currentStatus,
  };

  const attach = (instance) => {
    memory = instance.exports.memory;
    table = instance.exports.__indirect_function_table;
    if (!table) {
      throw new Error(
        "contrib/http: instance does not export __indirect_function_table " +
        "— recompile with a current `mere -w` (Phase 48.2+)"
      );
    }
  };

  return { glue, attach };
}

module.exports = { makeHttpGlue };

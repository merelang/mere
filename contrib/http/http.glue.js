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

const { makeWsEnv } = require("../../scripts/ws_env.js");

function makeHttpGlue() {
  let memory = null;
  let table = null;
  let langBump = null;  // exported __lang_bump global from the Wasm module

  const readCStr = (ptr) => {
    if (!memory) return "";
    const bytes = new Uint8Array(memory.buffer);
    let end = ptr;
    while (end < bytes.length && bytes[end] !== 0) end++;
    return Buffer.from(bytes.subarray(ptr, end)).toString("utf8");
  };

  // WebSocket hub — /ws/<channel> upgrade path. Hooked on the server's
  // `upgrade` event down in http_serve below. Extras (ws_broadcast /
  // ws_client_count) are merged into the returned glue object.
  const ws = makeWsEnv({ readCStr });

  // Allocate on the shared Mere bump heap so extern-returned strings
  // and Mere allocations never collide. Grow memory one 64KB page at
  // a time when needed. This replaces the older fixed 4KB scratch
  // region (56K..60K) — for realistic HTTP request bodies (multi-MB)
  // that region was too small and its wraparound corrupted Mere-side
  // strings that were live for the whole handler.
  const PAGE = 64 * 1024;
  const writeStr = (s) => {
    if (!memory || !langBump) return 0;
    const utf8 = Buffer.from(s, "utf8");
    const total = utf8.length + 1;
    const aligned = (total + 7) & ~7;
    const start = langBump.value;
    const needed = start + aligned;
    const capacity = memory.buffer.byteLength;
    if (needed > capacity) {
      const growPages = Math.ceil((needed - capacity) / PAGE);
      memory.grow(growPages);
    }
    const bytes = new Uint8Array(memory.buffer);
    bytes.set(utf8, start);
    bytes[start + utf8.length] = 0;
    langBump.value = start + aligned;
    return start;
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

  // SSE channel pool. Each channel maps to a Set of live `res` streams;
  // when the Mere side calls `sse_broadcast channel data` the glue
  // writes `data: <line>\n\n` to every subscriber. Clients that
  // disconnect are pruned by a per-res `close` listener. The Mere
  // handler is NOT invoked for `GET /sse/<channel>` — the connection
  // is hijacked at the http glue layer and held open until the client
  // (or the server) closes it.
  const sseChannels = new Map();  // channel → Set<res>

  // JS-callable version of sse_broadcast — exposed alongside `glue`
  // so a Node-side bridge (e.g. scripts/sse_redis_bridge.js) can fan
  // in messages from other transports without going through the
  // Mere-heap pointer boundary. The Mere-facing extern
  // `sse_broadcast` calls this same helper after decoding its args.
  const broadcast = (channel, payload) => {
    const set = sseChannels.get(channel);
    if (!set) return;
    const lines = String(payload).split("\n");
    const frame = lines.map((l) => "data: " + l).join("\n") + "\n\n";
    for (const res of set) {
      try { res.write(frame); } catch (e) { /* client gone */ }
    }
  };

  // Streaming-response state. When the Mere handler decides its
  // output is too big to buffer (large CSV export, tail -f style
  // log stream, etc.) it can call `http_stream_start ct status` to
  // send headers immediately, then repeatedly `http_stream_write s`
  // to push bytes as they're generated. On handler return the glue
  // finalizes with res.end() rather than the normal "one buffered
  // body then end" path.
  let activeRes = null;
  let streamStarted = false;

  const glue = {
    http_serve: (port, closurePtr) => {
      const http = require("http");
      const server = http.createServer((req, res) => {
        // /sse/<channel> — SSE upgrade path. Intercept before the
        // normal request/response Mere-callout path.
        if (req.method === "GET" && req.url && req.url.startsWith("/sse/")) {
          const channel = req.url.slice("/sse/".length).split("?")[0];
          res.writeHead(200, {
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
          });
          // Priming comment so clients see the connection open in dev
          // tools even before the first event.
          res.write(": connected\n\n");
          let set = sseChannels.get(channel);
          if (!set) { set = new Set(); sseChannels.set(channel, set); }
          set.add(res);
          const drop = () => {
            const s = sseChannels.get(channel);
            if (s) { s.delete(res); if (s.size === 0) sseChannels.delete(channel); }
          };
          req.on("close", drop);
          req.on("error", drop);
          return;
        }

        // Normal Mere-dispatched request. writeStr allocates on the
        // Mere heap, so no per-request reset needed.
        currentStatus = 200;
        currentContentType = "text/plain; charset=utf-8";
        currentHeaders = {};
        currentReqHeaders = req.headers || {};
        activeRes = res;
        streamStarted = false;
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
          if (streamStarted) {
            // Handler already sent headers + one or more chunks via
            // http_stream_start / http_stream_write. Its return value
            // (respBody) is a final trailing chunk — empty means the
            // handler wrote everything itself.
            if (respBody.length > 0) res.write(respBody);
            res.end();
          } else {
            const headers = { ...currentHeaders, "Content-Type": currentContentType };
            res.writeHead(currentStatus, headers);
            res.end(respBody);
          }
          activeRes = null;
          streamStarted = false;
        });
      });
      server.on("upgrade", (req, socket, head) => {
        if (ws.tryUpgrade(req, socket, head)) return;
        // Any other Upgrade request (e.g. HTTP/2 h2c) is not
        // supported — respond with 400 and close.
        socket.write(
          "HTTP/1.1 400 Bad Request\r\n" +
          "Connection: close\r\n" +
          "Content-Length: 0\r\n\r\n"
        );
        socket.destroy();
      });
      server.on("error", (e) => {
        console.error("contrib/http: server error:", e.message);
      });
      server.listen(port, () => {
        console.log(`contrib/http: listening on :${port}`);
      });
    },
    // Push a `data: <payload>\n\n` line to every client currently
    // subscribed to `channel`. Payload with embedded newlines is split
    // into multiple `data:` lines per the SSE spec. Called from Mere
    // via `extern fn sse_broadcast: str -> str -> unit`.
    // Begin a streaming response. Sends `HTTP/1.1 <status> ...` +
    // headers immediately, then leaves the connection open for
    // subsequent `http_stream_write` calls. Content-Type is set
    // from the arg; the extra Transfer-Encoding: chunked lets the
    // client start reading before the body length is known.
    // After this, the handler's normal `http_set_status` /
    // `http_set_header` / return-body are ignored (headers have
    // already flushed) — its return value is treated as one final
    // trailing chunk.
    http_stream_start: (ctPtr, statusCode) => {
      if (!activeRes || streamStarted) return;
      const ct = readCStr(ctPtr);
      const headers = {
        ...currentHeaders,
        "Content-Type": ct,
      };
      activeRes.writeHead(statusCode | 0 || 200, headers);
      streamStarted = true;
    },
    // Write one chunk to the active streaming response. Silently
    // no-ops if the handler forgot to call http_stream_start first
    // (or was already responding buffered).
    http_stream_write: (ptr) => {
      if (!activeRes || !streamStarted) return;
      try { activeRes.write(readCStr(ptr)); } catch (e) { /* client gone */ }
    },
    sse_broadcast: (channelPtr, payloadPtr) => {
      broadcast(readCStr(channelPtr), readCStr(payloadPtr));
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
    // WebSocket hub externs — see scripts/ws_env.js for the wire
    // protocol; contrib/http/websocket.mere for the extern decls.
    ...ws.extras,
  };

  const attach = (instance) => {
    memory = instance.exports.memory;
    table = instance.exports.__indirect_function_table;
    langBump = instance.exports.__lang_bump;
    if (!table) {
      throw new Error(
        "contrib/http: instance does not export __indirect_function_table " +
        "— recompile with a current `mere -w` (Phase 48.2+)"
      );
    }
    if (!langBump) {
      throw new Error(
        "contrib/http: instance does not export __lang_bump — recompile " +
        "with a current `mere -w` (needed so extern writes share the " +
        "Mere heap bump pointer)"
      );
    }
  };

  return { glue, attach, broadcast };
}

module.exports = { makeHttpGlue };

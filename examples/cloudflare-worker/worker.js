// worker.js — Cloudflare Worker entry.
//
// Playground snippet share: three routes handled by the Mere wasm
// module, with KV storage async-glued in JS around the sync Mere
// call:
//
//   GET  /            landing page
//   POST /share       raw code in body → returns {id, url}, stores in KV
//   GET  /s/:id       returns stored code, 404 if unknown
//
// The KV plumbing is intentionally OUTSIDE Mere. Cloudflare's KV
// bindings are async (Promise-based); Mere externs are sync. So:
//
//   Pre-fetch:  For GET /s/:id, we KV.get(id) BEFORE invoking the
//               Mere handler and pass the result as `kv_lookup` in
//               the request JSON.
//   Post-write: If the Mere response JSON carries a `kv_put` field,
//               we KV.put() AFTER the handler returns. That's the
//               "outbox pattern" — Mere emits intent, JS executes.

import wasmModule from "./main.wasm";

let memory = null;
let table = null;
let langBump = null;
let handlerClosurePtr = null;

const PAGE = 64 * 1024;

const readCStr = (ptr) => {
  const bytes = new Uint8Array(memory.buffer);
  let end = ptr;
  while (end < bytes.length && bytes[end] !== 0) end++;
  return new TextDecoder("utf-8").decode(bytes.subarray(ptr, end));
};

const writeStr = (s) => {
  const utf8 = new TextEncoder().encode(s + "\0");
  const aligned = (utf8.length + 7) & ~7;
  const start = langBump.value;
  const needed = start + aligned;
  const capacity = memory.buffer.byteLength;
  if (needed > capacity) {
    const growPages = Math.ceil((needed - capacity) / PAGE);
    memory.grow(growPages);
  }
  new Uint8Array(memory.buffer).set(utf8, start);
  langBump.value = start + aligned;
  return start;
};

const callHandler = (reqJson) => {
  if (handlerClosurePtr === null) {
    throw new Error("Mere handler was never registered — did main() run?");
  }
  const view = new DataView(memory.buffer);
  const env = view.getInt32(handlerClosurePtr, true);
  const fnIdx = view.getInt32(handlerClosurePtr + 4, true);
  const argPtr = writeStr(reqJson);
  const resultPtr = table.get(fnIdx)(env, argPtr);
  return readCStr(resultPtr);
};

// Per-request scratch — the JS glue writes these before invoking the
// Mere handler; the handler pulls them via cf_body / cf_kv_lookup.
// Passing arbitrary body text out-of-band (rather than embedded in
// the request JSON) sidesteps JSON escape round-trips that would
// otherwise mangle snippets containing newlines / quotes / backslashes.
let currentBody = "";
let currentKvLookup = "";

const stub = () => 0;
const env = {
  cf_on_fetch: (closurePtr) => { handlerClosurePtr = closurePtr; },
  cf_body: () => writeStr(currentBody),
  cf_kv_lookup: () => writeStr(currentKvLookup),
  gen_request_id: () => {
    // 16 hex chars from crypto.getRandomValues (available on CF Workers).
    const bytes = new Uint8Array(8);
    crypto.getRandomValues(bytes);
    return writeStr(
      Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("")
    );
  },
  puts: (ptr) => { console.log(readCStr(ptr)); },
  read_file: stub,
  write_file: stub,
  __lang_str_of_float: stub,
  __lang_float_of_str: () => 0.0,
  __lang_sin: Math.sin,
  __lang_cos: Math.cos,
  __lang_tan: Math.tan,
  __lang_f_pow: Math.pow,
  __lang_atan2: Math.atan2,
};

let instantiated = null;
const ensureReady = async () => {
  if (instantiated) return instantiated;
  const instance = await WebAssembly.instantiate(wasmModule, { env });
  memory = instance.exports.memory;
  table = instance.exports.__indirect_function_table;
  langBump = instance.exports.__lang_bump;
  instance.exports.main();
  instantiated = instance;
  return instance;
};

// Envelope handed to Mere is method + path + headers only. Body and
// pre-fetched KV value are stashed in module-level scratch (see the
// currentBody / currentKvLookup vars above); the handler pulls them
// via the cf_body / cf_kv_lookup externs. That avoids the JSON escape
// round-trip pitfall for arbitrary-content strings.
const requestToJson = (request) => {
  const url = new URL(request.url);
  const headers = {};
  request.headers.forEach((v, k) => { headers[k] = v; });
  return JSON.stringify({
    method: request.method,
    path: url.pathname + url.search,
    headers,
  });
};

const jsonToResponse = (jsonStr) => {
  let parsed;
  try {
    parsed = JSON.parse(jsonStr);
  } catch (e) {
    return { response: new Response(
      "worker: Mere handler returned non-JSON: " + jsonStr,
      { status: 500 }
    ) };
  }
  const response = new Response(parsed.body ?? "", {
    status: parsed.status ?? 200,
    headers: parsed.headers ?? {},
  });
  return { response, kv_put: parsed.kv_put || null };
};

export default {
  async fetch(request, env_) {
    try {
      await ensureReady();

      // Stash body + pre-fetched KV value in module scratch so Mere
      // can pull them via cf_body / cf_kv_lookup externs.
      currentBody = ["GET", "HEAD"].includes(request.method)
        ? ""
        : await request.text();

      const url = new URL(request.url);
      currentKvLookup = "";
      if (url.pathname.startsWith("/s/") && env_ && env_.MERE_SNIPPETS) {
        const id = url.pathname.slice(3);
        currentKvLookup = (await env_.MERE_SNIPPETS.get(id)) || "";
      }

      const reqJson = requestToJson(request);
      const respJson = callHandler(reqJson);
      const { response, kv_put } = jsonToResponse(respJson);

      // KV binding write for POST /share — post-process after Mere.
      if (kv_put && env_ && env_.MERE_SNIPPETS) {
        await env_.MERE_SNIPPETS.put(kv_put.key, kv_put.value);
      }
      return response;
    } catch (e) {
      return new Response("worker error: " + e.message, { status: 500 });
    }
  },
};

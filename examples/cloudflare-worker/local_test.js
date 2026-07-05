// local_test.js — Node smoke test for the snippet-share Worker.
//
// Mocks the KV binding with an in-memory Map so the flow is verifiable
// without wrangler / miniflare. Same request/response shapes as CF.
//
// Usage:
//   sh build.sh
//   node local_test.js

import fs from "node:fs";

const wasmBytes = fs.readFileSync(new URL("./main.wasm", import.meta.url));
globalThis.__test_wasm = new WebAssembly.Module(wasmBytes);

const workerSource = fs
  .readFileSync(new URL("./worker.js", import.meta.url), "utf8")
  .replace(
    'import wasmModule from "./main.wasm";',
    "const wasmModule = globalThis.__test_wasm;"
  );
const workerModuleUrl =
  "data:text/javascript;base64," +
  Buffer.from(workerSource, "utf8").toString("base64");
const worker = (await import(workerModuleUrl)).default;

// In-memory KV mock matching the Cloudflare binding surface (get / put).
const kv = new Map();
const kvBinding = {
  async get(key) {
    return kv.has(key) ? kv.get(key) : null;
  },
  async put(key, value) {
    kv.set(key, value);
  },
};

const env = { MERE_SNIPPETS: kvBinding };

const call = async (method, path, body) => {
  const req = new Request("http://localhost" + path, {
    method,
    body: body ? body : undefined,
  });
  const resp = await worker.fetch(req, env);
  const text = await resp.text();
  return { status: resp.status, headers: Object.fromEntries(resp.headers), body: text };
};

const check = (label, actual, expected) => {
  const pass = JSON.stringify(actual) === JSON.stringify(expected);
  if (pass) console.log(`  ok   ${label}`);
  else {
    console.log(`  FAIL ${label}`);
    console.log(`       expected: ${JSON.stringify(expected)}`);
    console.log(`       actual:   ${JSON.stringify(actual)}`);
  }
  return pass;
};

let allOk = true;
const record = (b) => { if (!b) allOk = false; };

console.log("=== snippet-share smoke test ===\n");

// 1. Landing page
console.log("1. GET / landing");
const r1 = await call("GET", "/", null);
record(check("status", r1.status, 200));
record(check("content-type starts with text/html",
  r1.headers["content-type"].startsWith("text/html"), true));
console.log(`     body preview: ${r1.body.slice(0, 60)}...`);
console.log("");

// 2. POST /share stores + returns id
console.log("2. POST /share stores a snippet");
const code = "let x = 1 in\nlet y = 2 in\nx + y";
const r2 = await call("POST", "/share", code);
record(check("status", r2.status, 201));
const parsed = JSON.parse(r2.body);
record(check("id length is 8 hex", parsed.id.length, 8));
record(check("url shape", parsed.url, `/s/${parsed.id}`));
record(check("KV was written", kv.has(parsed.id), true));
console.log(`     id: ${parsed.id}, url: ${parsed.url}`);
console.log("");

// 3. GET /s/:id round-trips the code back
console.log("3. GET /s/:id retrieves stored snippet");
const r3 = await call("GET", parsed.url, null);
record(check("status", r3.status, 200));
record(check("body matches original", r3.body, code));
console.log("");

// 4. GET /s/nonexistent → 404
console.log("4. GET /s/nonexistent returns 404");
const r4 = await call("GET", "/s/deadbeef", null);
record(check("status", r4.status, 404));
console.log("");

// 5. POST /share with empty body → 400
console.log("5. POST /share with empty body → 400");
const r5 = await call("POST", "/share", "");
record(check("status", r5.status, 400));
console.log("");

// 6. Unknown route → 404
console.log("6. GET /unknown → 404");
const r6 = await call("GET", "/unknown", null);
record(check("status", r6.status, 404));
console.log("");

console.log(allOk ? "=== all pass ===" : "=== FAILURES ===");
process.exit(allOk ? 0 : 1);

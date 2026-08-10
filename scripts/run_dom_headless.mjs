// scripts/run_dom_headless.mjs — run a contrib/dom program under Node.
//
// Browser-targeted Mere had no way to be tested without a browser, so
// the frontend FFI was only ever exercised by hand. This supplies just
// enough of a DOM — plus fetch, synchronous XHR and EventSource — to
// instantiate a `mere -w` module against contrib/dom/dom.glue.js, drive
// it, and print the element tree it built.
//
// Usage:
//   node scripts/run_dom_headless.mjs <app.wasm> [base-url] [options]
//
//   --set <id>=<value>     seed an input's value before main() runs
//   --fire <id>:<event>    dispatch an event after main() (repeatable)
//   --type <id>=<text>     set a field's value and fire `input`, the way
//                          a keystroke does (repeatable, in order)
//   --pick <id>=<value>    choose in a <select>: set value, fire `change`
//   --check <id>=<0|1>     toggle a checkbox: set `checked`, fire `change`
//   --wait <ms>            settle time after the last --fire (default 1000)
//   --settle <ms>          settle time after main() before firing (default 300)
//   --worker <store.wasm>  a second module that owns storage, reached
//                          through worker_call (replies land in a later
//                          turn, as a Worker or a network would)
//
// Example (with examples/http_chat.mere serving on :8080):
//   node scripts/run_dom_headless.mjs examples/chat/app.wasm \
//     http://localhost:8080 --set text=hello --fire compose:submit
//
// Elements are created on demand, so a program can ask for any id and
// get a working handle — no page fixture to keep in sync.

import { readFileSync } from "node:fs";
import * as fsSync from "node:fs";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const { makeDomGlue } = await import(
  join(here, "..", "contrib", "dom", "dom.glue.js")
);

const argv = process.argv.slice(2);
const positional = argv.filter((a) => !a.startsWith("--") &&
  !(argv[argv.indexOf(a) - 1] || "").startsWith("--"));
const optValues = (name) =>
  argv.flatMap((a, i) => (a === `--${name}` ? [argv[i + 1]] : []));

const wasmPath = positional[0];
const baseUrl = positional[1] || "http://localhost:8080";
const waitMs = parseInt(optValues("wait")[0] || "1000", 10);

if (!wasmPath) {
  console.error("usage: run_dom_headless.mjs <app.wasm> [base-url] [--set id=v] [--fire id:event]");
  process.exit(2);
}

// ---- minimal DOM ----------------------------------------------------

class El {
  constructor(tag, id) {
    this.tagName = tag;
    this.id = id || "";
    this.children = [];
    this.attributes = {};
    this._text = "";
    this.value = "";
    this.listeners = {};
    this.scrollTop = 0;
    this.scrollHeight = 0;
    // A checkbox's meaning lives here, not in `value`. `type` is what the
    // glue looks at to decide which of the two a `change` is about.
    this.checked = false;
    this.type = "";
  }
  get textContent() {
    return this.children.length
      ? this.children.map((c) => c.textContent).join("")
      : this._text;
  }
  set textContent(v) {
    this._text = String(v);
    this.children = [];
  }
  setAttribute(k, v) {
    this.attributes[k] = v;
    // An element the program created becomes addressable once it names
    // itself, so --fire can reach a row's button.
    if (k === "id") { this.id = v; byId.set(v, this); }
  }
  removeAttribute(k) { delete this.attributes[k]; }
  appendChild(c) { c.parent = this; this.children.push(c); return c; }
  remove() {
    const p = this.parent;
    if (p) { p.children = p.children.filter((c) => c !== this); this.parent = null; }
  }
  addEventListener(ev, fn) { (this.listeners[ev] ||= []).push(fn); }
  fire(ev, obj = {}) {
    for (const fn of this.listeners[ev] || []) fn({ preventDefault() {}, ...obj });
  }
  dump(indent = "") {
    const attrs = Object.entries(this.attributes)
      .map(([k, v]) => ` ${k}="${v}"`).join("");
    // A form's state is in `value` and `checked`, not in text — without
    // these a dump of a filled-in form looks identical to an empty one.
    const props =
      (this.value ? ` value="${this.value}"` : "") +
      (this.checked ? ` checked` : "");
    const open = `${indent}<${this.tagName}${attrs}${props}>`;
    if (!this.children.length) {
      return this._text ? `${open}${this._text}` : open;
    }
    return [open, ...this.children.map((c) => c.dump(indent + "  "))].join("\n");
  }
}

const byId = new Map();
const lookup = (id) => {
  if (!byId.has(id)) byId.set(id, new El("div", id));
  return byId.get(id);
};

globalThis.document = {
  getElementById: lookup,
  createElement: (tag) => new El(tag),
  addEventListener: () => {},
};

for (const pair of optValues("set")) {
  const eq = pair.indexOf("=");
  lookup(pair.slice(0, eq)).value = pair.slice(eq + 1);
}

// ---- network --------------------------------------------------------

const absolute = (url) => new URL(url, baseUrl).toString();

// Node has no synchronous HTTP, so `curl` stands in for the browser's
// synchronous XMLHttpRequest — same blocking semantics from the
// program's point of view.
globalThis.XMLHttpRequest = class {
  open(method, url) { this._method = method; this._url = url; this._headers = []; }
  setRequestHeader(k, v) { this._headers.push("-H", `${k}: ${v}`); }
  send(body) {
    const args = ["-sS", "-w", "\n__STATUS__%{http_code}", "-X", this._method,
      ...this._headers];
    if (body) args.push("--data-binary", body);
    args.push(absolute(this._url));
    const r = spawnSync("curl", args, { encoding: "utf8", maxBuffer: 16 * 1024 * 1024 });
    const out = r.stdout || "";
    const marker = out.lastIndexOf("\n__STATUS__");
    this.responseText = marker < 0 ? out : out.slice(0, marker);
    this.status = marker < 0 ? 0 : parseInt(out.slice(marker + 11), 10) || 0;
  }
};

const nodeFetch = globalThis.fetch;
globalThis.fetch = (url, init) => nodeFetch(absolute(url), init);

if (!globalThis.EventSource) {
  const { get } = await import("node:http");
  globalThis.EventSource = class {
    constructor(url) {
      this.onopen = this.onerror = this.onmessage = null;
      get(absolute(url), (res) => {
        this.onopen && this.onopen();
        let buf = "";
        res.on("data", (chunk) => {
          buf += chunk;
          let sep;
          while ((sep = buf.indexOf("\n\n")) >= 0) {
            const frame = buf.slice(0, sep);
            buf = buf.slice(sep + 2);
            for (const line of frame.split("\n")) {
              if (line.startsWith("data: ") && this.onmessage) {
                this.onmessage({ data: line.slice(6) });
              }
            }
          }
        });
      }).on("error", () => this.onerror && this.onerror());
    }
  };
}

// ---- storage module (--worker) --------------------------------------
//
// A second Mere module, the one that owns durable state. In a browser it
// runs inside a Worker so it can use an OPFS access handle; here it runs
// in this process against the filesystem. What matters for the app under
// test is that its replies arrive in a LATER turn, so the deferral below
// is deliberate rather than an artifact of the harness.

const makeStoreHost = async (wasmPath) => {
  let memory = null, table = null, langBump = null, handler = null;
  const PAGE = 64 * 1024;
  const openFiles = [undefined];

  const readStr = (ptr) => {
    const bytes = new Uint8Array(memory.buffer);
    let end = ptr;
    while (end < bytes.length && bytes[end] !== 0) end++;
    return Buffer.from(bytes.subarray(ptr, end)).toString("utf8");
  };
  // Mere str layout: [i32 len][bytes][NUL], value points at byte0.
  const writeStr = (s) => {
    const utf8 = Buffer.from(s, "utf8");
    const aligned = (4 + utf8.length + 1 + 7) & ~7;
    const start = langBump.value;
    if (start + aligned > memory.buffer.byteLength) {
      memory.grow(Math.ceil((start + aligned - memory.buffer.byteLength) / PAGE));
    }
    new DataView(memory.buffer).setInt32(start, utf8.length, true);
    const mem = new Uint8Array(memory.buffer);
    mem.set(utf8, start + 4);
    mem[start + 4 + utf8.length] = 0;
    langBump.value = start + aligned;
    return start + 4;
  };
  const bumpAlloc = (n) => {
    const aligned = (n + 7) & ~7;
    const start = langBump.value;
    if (start + aligned > memory.buffer.byteLength) {
      memory.grow(Math.ceil((start + aligned - memory.buffer.byteLength) / PAGE));
    }
    langBump.value = start + aligned;
    return start;
  };

  const stub = () => 0;
  const env = {
    puts: () => 0,
    time: () => Date.now() / 1000,
    read_file: stub,
    write_file: stub,
    __lang_str_of_float: stub,
    __lang_float_of_str: () => 0.0,
    __lang_sin: Math.sin, __lang_cos: Math.cos, __lang_tan: Math.tan,
    __lang_f_pow: Math.pow, __lang_atan2: Math.atan2,
    // The positioned file I/O the store is built on (v0.1.153). An OPFS
    // access handle offers exactly these five operations, which is why
    // the same store source compiles for a browser Worker.
    file_openrw: (pathPtr) => {
      const path = readStr(pathPtr);
      try {
        let fd;
        try { fd = fsSync.openSync(path, "r+"); }
        catch (e) { fd = fsSync.openSync(path, "w+"); }
        openFiles.push(fd);
        return openFiles.length - 1;
      } catch (e) { return 0; }
    },
    file_size: (pathPtr) => {
      try { return fsSync.statSync(readStr(pathPtr)).size; } catch (e) { return 0; }
    },
    file_pread: (handle, off, len) => {
      const fd = openFiles[handle];
      const buf = Buffer.alloc(Math.max(0, len));
      let got = 0;
      if (fd !== undefined && len > 0 && off >= 0) {
        try { got = fsSync.readSync(fd, buf, 0, len, off); } catch (e) { got = 0; }
      }
      const ptr = bumpAlloc(4 + got);
      new DataView(memory.buffer).setInt32(ptr, got, true);
      new Uint8Array(memory.buffer).set(buf.subarray(0, got), ptr + 4);
      return ptr;
    },
    file_pwrite: (handle, off, bytesPtr) => {
      const fd = openFiles[handle];
      if (fd === undefined || off < 0) return 0;
      const len = new DataView(memory.buffer).getInt32(bytesPtr, true);
      const mem = new Uint8Array(memory.buffer);
      const src = Buffer.from(mem.subarray(bytesPtr + 4, bytesPtr + 4 + len));
      try { return fsSync.writeSync(fd, src, 0, len, off); } catch (e) { return 0; }
    },
    file_fsync: (handle) => {
      const fd = openFiles[handle];
      if (fd !== undefined) { try { fsSync.fsyncSync(fd); } catch (e) {} }
      return 0;
    },
    file_close: (handle) => {
      const fd = openFiles[handle];
      if (fd !== undefined) { try { fsSync.closeSync(fd); } catch (e) {} openFiles[handle] = undefined; }
      return 0;
    },
    // The store registers its message handler exactly as an HTTP handler
    // registers with http_serve: the host keeps the closure and calls it
    // per message.
    worker_serve: (closurePtr) => { handler = closurePtr; },
  };

  const { instance } = await WebAssembly.instantiate(readFileSync(wasmPath), { env });
  memory = instance.exports.memory;
  table = instance.exports.__indirect_function_table;
  langBump = instance.exports.__lang_bump;
  instance.exports.main();

  return (request) => {
    if (handler === null) return "";
    const view = new DataView(memory.buffer);
    const envPtr = view.getInt32(handler, true);
    const fnIdx = view.getInt32(handler + 4, true);
    const fn = table.get(fnIdx);
    const argPtr = writeStr(request);
    const reply = fn(BigInt(envPtr), BigInt(argPtr));
    return readStr(typeof reply === "bigint" ? Number(reply) : reply);
  };
};

// ---- run ------------------------------------------------------------

const { glue, attach, setWorkerTransport } = makeDomGlue();

const workerPath = optValues("worker")[0];
if (workerPath) {
  const storeCall = await makeStoreHost(workerPath);
  // Reply in a later turn, the way a Worker or a network would.
  setWorkerTransport((request) =>
    new Promise((resolve) => setTimeout(() => resolve(storeCall(request)), 0)));
}
const stub = () => 0;
const env = {
  ...glue,
  // The prelude imports the float / libm set whether or not the program
  // does float math, so they all have to resolve.
  puts: () => 0,
  time: () => Date.now() / 1000,
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

const { instance } = await WebAssembly.instantiate(readFileSync(wasmPath), { env });
attach(instance);
instance.exports.main();

// An app whose startup is asynchronous has not drawn anything yet when
// main() returns, so nothing is clickable until its first round trips
// land. Settle before reporting or firing.
const settleMs = parseInt(optValues("settle")[0] || "300", 10);
await new Promise((r) => setTimeout(r, settleMs));

const report = (label) => {
  console.log(`\n===== ${label} =====`);
  for (const [id, el] of byId) {
    const body = el.dump("  ");
    console.log(`#${id}:\n${body}`);
  }
};

report("after main()");

// --type and --fire run in the order they appear on the command line, so
// a filter can be typed and then a button pressed in one run.
const actions = [];
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === "--type") actions.push(["type", argv[i + 1]]);
  if (argv[i] === "--pick") actions.push(["pick", argv[i + 1]]);
  if (argv[i] === "--check") actions.push(["check", argv[i + 1]]);
  if (argv[i] === "--fire") actions.push(["fire", argv[i + 1]]);
}
for (const [kind, spec] of actions) {
  if (kind === "type") {
    const eq = spec.indexOf("=");
    const el = lookup(spec.slice(0, eq));
    el.value = spec.slice(eq + 1);
    el.fire("input");
  } else if (kind === "pick") {
    // A <select>: the user picks, and the only event is `change`.
    const eq = spec.indexOf("=");
    const el = lookup(spec.slice(0, eq));
    el.value = spec.slice(eq + 1);
    el.fire("change");
  } else if (kind === "check") {
    // A checkbox has no value worth reading; toggling it is a change of
    // `checked`, and `type` is how the glue knows to report that instead.
    const eq = spec.indexOf("=");
    const el = lookup(spec.slice(0, eq));
    el.type = "checkbox";
    el.checked = spec.slice(eq + 1) !== "0";
    el.fire("change");
  } else {
    const colon = spec.lastIndexOf(":");
    lookup(spec.slice(0, colon)).fire(spec.slice(colon + 1));
  }
}

if (actions.length > 0) {
  await new Promise((r) => setTimeout(r, waitMs));
  report(`after ${actions.map(([k, v]) => `${k} ${v}`).join(", ")}`);
}

process.exit(0);

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
//   --wait <ms>            settle time after the last --fire (default 1000)
//
// Example (with examples/http_chat.mere serving on :8080):
//   node scripts/run_dom_headless.mjs examples/chat/app.wasm \
//     http://localhost:8080 --set text=hello --fire compose:submit
//
// Elements are created on demand, so a program can ask for any id and
// get a working handle — no page fixture to keep in sync.

import { readFileSync } from "node:fs";
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
  setAttribute(k, v) { this.attributes[k] = v; }
  appendChild(c) { this.children.push(c); return c; }
  addEventListener(ev, fn) { (this.listeners[ev] ||= []).push(fn); }
  fire(ev, obj = {}) {
    for (const fn of this.listeners[ev] || []) fn({ preventDefault() {}, ...obj });
  }
  dump(indent = "") {
    const attrs = Object.entries(this.attributes)
      .map(([k, v]) => ` ${k}="${v}"`).join("");
    const open = `${indent}<${this.tagName}${attrs}>`;
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

// ---- run ------------------------------------------------------------

const { glue, attach } = makeDomGlue();
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

const report = (label) => {
  console.log(`\n===== ${label} =====`);
  for (const [id, el] of byId) {
    const body = el.dump("  ");
    console.log(`#${id}:\n${body}`);
  }
};

report("after main()");

for (const spec of optValues("fire")) {
  const colon = spec.lastIndexOf(":");
  lookup(spec.slice(0, colon)).fire(spec.slice(colon + 1));
}

if (optValues("fire").length > 0) {
  await new Promise((r) => setTimeout(r, waitMs));
  report(`after ${optValues("fire").join(", ")}`);
}

process.exit(0);

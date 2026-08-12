// scripts/wasm_sourcemap.js — build a source map for a compiled Mere program, so
// a browser's debugger shows the .mere source rather than disassembled Wasm.
//
//   mere -w  app.mere > app.wat
//   mere -wg app.mere > app.map.txt
//   wat2wasm --debug-names app.wat -o app.wasm
//   node scripts/wasm_sourcemap.js app.wasm app.map.txt app.mere
//
// Writes app.wasm.map and appends a `sourceMappingURL` custom section to
// app.wasm pointing at it. Chrome and Firefox read that section, fetch the map,
// and show Mere source in the debugger.
//
// Why this is a tool and not part of the compiler: a Wasm source map maps *byte
// offsets in the assembled binary*, and the compiler emits text for wat2wasm to
// assemble. Nobody in that chain knows both halves — the compiler knows which
// function came from which line (`mere -wg`), the binary knows where each
// function is (its name section), and this matches them up. Same division as the
// RV32I debug map, for the same reason.
//
// Two things about the format that are easy to get wrong, and are why the
// mappings are built the way they are below:
//
//   * Every mapping is on generated line 0, and the "column" is the byte offset
//     into the .wasm file. That is the Wasm convention, not an approximation.
//   * Segments are VLQ, and every field except the first is a *delta* from the
//     previous segment. Sorted by offset, therefore, or the deltas are nonsense.

const fs = require("fs");
const path = require("path");

function fail(msg) {
  console.error(`wasm_sourcemap: ${msg}`);
  process.exit(1);
}

// --- reading the binary ----------------------------------------------------

function readVarUint(buf, pos) {
  let result = 0;
  let shift = 0;
  let byte;
  do {
    if (pos >= buf.length) fail("truncated LEB128");
    byte = buf[pos++];
    result |= (byte & 0x7f) << shift;
    shift += 7;
  } while (byte & 0x80);
  return [result >>> 0, pos];
}

// Walk the sections and return, for each one, its id and where its payload
// starts and ends. Everything else here is a question about one section.
function sections(buf) {
  if (buf.readUInt32LE(0) !== 0x6d736100) fail("not a wasm file");
  let pos = 8;
  const out = [];
  while (pos < buf.length) {
    const id = buf[pos++];
    let size;
    [size, pos] = readVarUint(buf, pos);
    out.push({ id, start: pos, end: pos + size });
    pos += size;
  }
  return out;
}

// Function index -> name, from the name section (subsection 1). Requires the
// binary to have been assembled with --debug-names; without it there is nothing
// to match the compiler's table against, and that is worth saying plainly rather
// than producing an empty map.
function functionNames(buf, secs) {
  const custom = secs.filter((s) => s.id === 0);
  for (const sec of custom) {
    let pos = sec.start;
    let len;
    [len, pos] = readVarUint(buf, pos);
    const name = buf.toString("utf8", pos, pos + len);
    pos += len;
    if (name !== "name") continue;
    const names = new Map();
    while (pos < sec.end) {
      const subId = buf[pos++];
      let subSize;
      [subSize, pos] = readVarUint(buf, pos);
      const subEnd = pos + subSize;
      if (subId === 1) {
        let count;
        [count, pos] = readVarUint(buf, pos);
        for (let i = 0; i < count; i++) {
          let idx, nlen;
          [idx, pos] = readVarUint(buf, pos);
          [nlen, pos] = readVarUint(buf, pos);
          names.set(idx, buf.toString("utf8", pos, pos + nlen));
          pos += nlen;
        }
      }
      pos = subEnd;
    }
    return names;
  }
  return null;
}

// Function index -> byte offset of its body. The code section holds only the
// defined functions, which are numbered after the imported ones, so the index
// space starts at however many functions were imported.
function bodyOffsets(buf, secs) {
  const importCount = countImportedFunctions(buf, secs);
  const code = secs.find((s) => s.id === 10);
  if (!code) fail("no code section");
  let pos = code.start;
  let count;
  [count, pos] = readVarUint(buf, pos);
  const offsets = new Map();
  for (let i = 0; i < count; i++) {
    let size;
    [size, pos] = readVarUint(buf, pos);
    offsets.set(importCount + i, pos);
    pos += size;
  }
  return offsets;
}

function countImportedFunctions(buf, secs) {
  const imports = secs.find((s) => s.id === 2);
  if (!imports) return 0;
  let pos = imports.start;
  let count;
  [count, pos] = readVarUint(buf, pos);
  let funcs = 0;
  for (let i = 0; i < count; i++) {
    let len;
    [len, pos] = readVarUint(buf, pos); pos += len;   // module
    [len, pos] = readVarUint(buf, pos); pos += len;   // field
    const kind = buf[pos++];
    if (kind === 0x00) { funcs++; [, pos] = readVarUint(buf, pos); }
    else if (kind === 0x01) { pos++; pos = skipLimits(buf, pos); }
    else if (kind === 0x02) { pos = skipLimits(buf, pos); }
    else if (kind === 0x03) { pos += 2; }
    else fail(`unknown import kind ${kind}`);
  }
  return funcs;
}

function skipLimits(buf, pos) {
  const flags = buf[pos++];
  [, pos] = readVarUint(buf, pos);
  if (flags & 1) [, pos] = readVarUint(buf, pos);
  return pos;
}

// --- writing the map -------------------------------------------------------

const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

function vlq(value) {
  let v = value < 0 ? (-value << 1) | 1 : value << 1;
  let out = "";
  do {
    let digit = v & 31;
    v >>>= 5;
    if (v > 0) digit |= 32;
    out += B64[digit];
  } while (v > 0);
  return out;
}

function buildMappings(entries) {
  let prevOffset = 0;
  let prevLine = 0;
  return entries
    .map((e) => {
      const seg =
        vlq(e.offset - prevOffset) + vlq(0) + vlq(e.line - 1 - prevLine) + vlq(0);
      prevOffset = e.offset;
      prevLine = e.line - 1;
      return seg;
    })
    .join(",");
}

// --- the custom section ----------------------------------------------------

function varuint(n) {
  const bytes = [];
  do {
    let byte = n & 0x7f;
    n >>>= 7;
    if (n !== 0) byte |= 0x80;
    bytes.push(byte);
  } while (n !== 0);
  return Buffer.from(bytes);
}

function withSourceMappingURL(buf, secs, url) {
  // Drop any sourceMappingURL section already there, so running this twice does
  // not leave two.
  const kept = [];
  let last = 8;
  const pieces = [buf.subarray(0, 8)];
  for (const sec of secs) {
    let pos = sec.start;
    let len;
    [len, pos] = readVarUint(buf, pos);
    const name = buf.toString("utf8", pos, pos + len);
    const headerStart = sectionHeaderStart(buf, sec);
    if (sec.id === 0 && name === "sourceMappingURL") {
      pieces.push(buf.subarray(last, headerStart));
      last = sec.end;
    }
    kept.push(sec);
  }
  pieces.push(buf.subarray(last));
  const body = Buffer.concat([
    varuint(Buffer.byteLength("sourceMappingURL")),
    Buffer.from("sourceMappingURL"),
    varuint(Buffer.byteLength(url)),
    Buffer.from(url),
  ]);
  return Buffer.concat([
    Buffer.concat(pieces),
    Buffer.from([0]),
    varuint(body.length),
    body,
  ]);
}

// Where a section's header (its id byte) begins, given where its payload does.
function sectionHeaderStart(buf, sec) {
  let size = sec.end - sec.start;
  let bytes = 0;
  do { bytes++; size >>>= 7; } while (size > 0);
  return sec.start - bytes - 1;
}

// --- main ------------------------------------------------------------------

const [wasmPath, tablePath, sourcePath] = process.argv.slice(2);
if (!wasmPath || !tablePath || !sourcePath) {
  console.error(
    "usage: node scripts/wasm_sourcemap.js <app.wasm> <table from mere -wg> <app.mere>"
  );
  process.exit(2);
}

const wasm = fs.readFileSync(wasmPath);
const secs = sections(wasm);
const names = functionNames(wasm, secs);
if (!names) {
  fail("no name section — assemble with `wat2wasm --debug-names`, or there is nothing to match");
}
const offsets = bodyOffsets(wasm, secs);

const table = new Map();
for (const line of fs.readFileSync(tablePath, "utf8").split("\n")) {
  const m = /^F (\S+) (\d+)$/.exec(line);
  if (m) table.set(m[1], parseInt(m[2], 10));
}
if (table.size === 0) fail(`no entries in ${tablePath}`);

const entries = [];
for (const [index, name] of names) {
  const line = table.get(name);
  const offset = offsets.get(index);
  if (line !== undefined && offset !== undefined) entries.push({ name, offset, line });
}
entries.sort((a, b) => a.offset - b.offset);
if (entries.length === 0) {
  fail("no function in the binary matched the table — was the .wat assembled from this source?");
}

const mapPath = `${wasmPath}.map`;
const map = {
  version: 3,
  file: path.basename(wasmPath),
  sources: [path.basename(sourcePath)],
  sourcesContent: [fs.readFileSync(sourcePath, "utf8")],
  names: [],
  mappings: buildMappings(entries),
};
fs.writeFileSync(mapPath, JSON.stringify(map));
fs.writeFileSync(wasmPath, withSourceMappingURL(wasm, secs, path.basename(mapPath)));

console.log(
  `wasm_sourcemap: ${entries.length} function${entries.length === 1 ? "" : "s"} mapped ` +
    `-> ${path.basename(mapPath)}`
);

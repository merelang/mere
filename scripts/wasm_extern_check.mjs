// Probe wrappers directly so high-bit pointers need no large memory or dereference.
import assert from 'node:assert/strict';
import fs from 'node:fs';
let pointer = 0, memory, output = '', units = 0;
const env = new Proxy({
  ffi_echo: x => x,
  ffi_alias: () => -1,
  ffi_first: (x, y) => x,
  ffi_text: () => pointer,
  ffi_handle: () => pointer,
  ffi_bool: x => x,
  ffi_unit: () => { units++; },
  puts: p => {
    const bytes = new Uint8Array(memory.buffer);
    let end = p;
    while (end < bytes.length && bytes[end]) end++;
    output += Buffer.from(bytes.subarray(p, end)).toString('utf8') + '\n';
  },
}, { get: (o, k) => k in o ? o[k] : () => 0 });
const { instance } = await WebAssembly.instantiate(fs.readFileSync(process.argv[2]), { env });
memory = instance.exports.memory;
const e = instance.exports;
for (const x of [-2147483648n, -1n, 0n, 2147483647n, 2147483648n, 4294967295n])
  assert.equal(e.probe_ffi_echo(x), BigInt.asIntN(32, x), 'signed result and wrapped argument');
assert.equal(e.probe_ffi_alias(), -1n, 'integer alias');
assert.equal(e.probe_ffi_first(-1n, 42n), -1n, 'curried extern result');
for (pointer of [0, 0x7fffffff, 0x80000000, 0xffffffff]) {
  assert.equal(e.probe_ffi_text(), BigInt(pointer), 'string address bits');
  assert.equal(e.probe_ffi_handle(), BigInt(pointer), 'opaque reference bits');
}
assert.equal(e.probe_ffi_bool(0n), 0n);
assert.equal(e.probe_ffi_bool(1n), 1n);
assert.equal(e.probe_ffi_unit(), undefined);
e.main();
assert.equal(output.trim(), '42', 'comparisons, partial application and unsigned mask');
assert.equal(units, 2, 'unit calls');
console.log('wasm extern contract passed');

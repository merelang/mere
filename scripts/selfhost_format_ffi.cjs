// An explicit integer-handle host shared by formatter CLI and browser checks.
const assert = require('node:assert/strict');
const fs = require('node:fs');

async function execute(binary) {
  let instance;
  const output = [];
  const unexpectedFloat = () => { throw new Error('integer fixture called a float conversion'); };
  const env = {
    puts(ptr) {
      const memory = instance.exports.memory.buffer;
      const length = new DataView(memory).getInt32(ptr - 4, true);
      assert.ok(length >= 0 && ptr + length <= memory.byteLength);
      output.push(Buffer.from(new Uint8Array(memory, ptr, length)).toString('utf8') + '\n');
    },
    format_token: value => value + 1000,
    format_value: handle => handle - 999,
    time: () => Date.now() / 1000,
    __lang_str_of_float: unexpectedFloat,
    __lang_float_of_str: unexpectedFloat,
    __lang_float_of_str_ok: unexpectedFloat,
    __lang_sin: Math.sin, __lang_cos: Math.cos, __lang_tan: Math.tan,
    __lang_exp: Math.exp, __lang_log: Math.log,
    __lang_f_pow: Math.pow, __lang_atan2: Math.atan2,
  };
  instance = (await WebAssembly.instantiate(binary, { env })).instance;
  instance.exports.main();
  return output.join('');
}

module.exports = execute;
if (require.main === module) {
  execute(fs.readFileSync(process.argv[2])).then(output => process.stdout.write(output))
    .catch(error => { console.error(error); process.exit(1); });
}

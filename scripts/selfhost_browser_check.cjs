#!/usr/bin/env node
// Exercise the shipped HTML host and optimized compiler, including recovery
// after a type failure. No fallback imports or compiler-output normalization.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');
const os = require('node:os');
const root = path.resolve(__dirname, '..');
const dataModule = text => 'data:text/javascript;base64,' + Buffer.from(text).toString('base64');

async function loadHost(playground, name, button, output) {
  const html = fs.readFileSync(path.join(playground, name + '.html'), 'utf8');
  const scripts = [...html.matchAll(/<script type="module">([\s\S]*?)<\/script>/g)];
  assert.equal(scripts.length, 1, 'exactly one ' + name + ' host');
  const glue = dataModule(fs.readFileSync(path.join(playground, 'dom.glue.js'), 'utf8'));
  const host = scripts[0][1].replace('"./dom.glue.js"', JSON.stringify(glue));
  assert.notEqual(host, scripts[0][1], 'host must import the real DOM glue');
  const wasm = fs.readFileSync(path.join(playground, name + '.wasm'));
  let callback, beforeClick;
  const elements = {
    input: { value: '' }, [output]: { textContent: '' },
    [button]: { addEventListener(event, fn, options) {
      assert.equal(event, 'click');
      if (options?.capture) beforeClick = fn;
      else callback = fn;
    } },
  };
  const document = {
    getElementById(id) { assert.ok(id in elements, id); return elements[id]; },
    addEventListener() {}, querySelectorAll() { return []; },
  };
  const fetch = async url => {
    assert.equal(url, './' + name + '.wasm');
    return { arrayBuffer: async () => wasm };
  };
  global.document = document;
  global.fetch = fetch;
  await import(dataModule(host));
  assert.equal(typeof callback, 'function', 'the actual ' + name + ' registers its handler');
  const errors = [];
  const run = source => {
    global.document = document;
    global.fetch = fetch;
    elements.input.value = source;
    const saved = console.error;
    console.error = (...args) => errors.push(args);
    try { beforeClick?.(); callback(); } finally { console.error = saved; }
    return elements[output].textContent;
  };
  return { run, errors };
}

async function check(playground) {
  const compiler = await loadHost(playground, 'selfhost-compile', 'compile-btn', 'result');
  const formatter = await loadHost(playground, 'selfhost-fmt', 'format-btn', 'output');
  const compile = compiler.run, format = formatter.run, errors = compiler.errors;
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'mere-browser-check-'));
  try {
    const wat = path.join(temporary, 'target.wat'), target = path.join(temporary, 'target.wasm');
    const execute = (source, expected, ffi = false) => {
      const before = errors.length;
      const output = compile(source);
      if (errors.length !== before) console.error(...errors.slice(before));
      assert.match(output, /^\(module\b/, 'valid input must emit a module');
      assert.equal(errors.length, before, 'valid compilation must not trap');
      fs.writeFileSync(wat, output);
      cp.execFileSync('wat2wasm', ['--enable-tail-call', wat, '-o', target]);
      const runner = ffi ? 'scripts/selfhost_format_ffi.cjs' : 'scripts/run_wasm.js';
      assert.equal(cp.execFileSync(process.execPath, [path.join(root, runner), target],
        { encoding: 'utf8', timeout: 120000 }), expected);
    };
    const layouts = fs.readFileSync(path.join(root, 'test/selfhost/format_declarations.tsv'), 'utf8').trimEnd().split('\n');
    assert.equal(layouts.length, 12, 'required declaration layouts');
    for (const row of layouts) {
      const [name, expected, source, ...extra] = row.split('\t');
      assert.equal(extra.length, 0, name);
      const formatted = format(source);
      assert.equal(formatted, JSON.parse(expected), name);
      assert.equal(format(formatted), formatted, name + ': idempotence');
    }
    const fixtures = ['t06_patterns', 't07_pattern_visibility', 't08_logic', 't09_records',
      't10_aliases', 't11_polymorphic_types', 't12_type_modules', 't13_type_scope',
      't14_annotations', 't15_constructors', 't16_constructor_scope'];
    let lines = 0;
    for (const name of fixtures) {
      console.log(`  browser oracle ${name}`);
      const file = path.join(root, 'test/selfhost', name);
      const expected = fs.readFileSync(file + '.expected', 'utf8');
      const source = fs.readFileSync(file + '.mere', 'utf8');
      execute(source, expected);
      const formatted = format(source);
      assert.equal(format(formatted), formatted, name + ': browser formatter idempotence');
      execute(formatted, expected);
      lines += expected.split('\n').length - 1;
    }
    const foreign = path.join(root, 'test/selfhost/format_externs');
    const foreignSource = fs.readFileSync(foreign + '.mere', 'utf8');
    const foreignExpected = fs.readFileSync(foreign + '.expected', 'utf8');
    execute(foreignSource, foreignExpected, true);
    execute(format(foreignSource), foreignExpected, true);
    assert.equal(formatter.errors.length, 0, 'valid formatting must not trap');
    console.log(`  browser formatter: 12 layouts, ${lines} oracle lines and extern signatures passed`);
    const prelude = path.join(root, 'test/selfhost/compiler_prelude');
    execute(fs.readFileSync(prelude + '.mere', 'utf8'), fs.readFileSync(prelude + '.expected', 'utf8'));
    console.log('  browser standard helpers: 3 handwritten answers passed');
    const helperRows = fs.readFileSync(path.join(root, 'test/selfhost/compiler_helpers.tsv'), 'utf8').trimEnd().split('\n');
    assert.equal(helperRows.length, 17, 'required helper inventory');
    for (const row of helperRows) {
      const [name, answers, source, ...extra] = row.split('\t');
      assert.equal(extra.length, 0, name);
      execute(source, JSON.parse(answers).join('\n') + '\n');
    }
    console.log('  browser helper inventory: 17 compatibility cases passed');
    let refusals = 0;
    for (const [inventory, columns] of [['record_rejections', 4], ['type_rejections', 4], ['declaration_rejections', 5]]) {
      const rows = fs.readFileSync(path.join(root, 'test/selfhost', inventory + '.tsv'), 'utf8').trimEnd().split('\n');
      assert.equal(rows.length, { record_rejections: 9, type_rejections: 19, declaration_rejections: 33 }[inventory]);
      for (const row of rows) {
        const fields = row.split('\t'); assert.equal(fields.length, columns);
        const name = fields[0], reason = fields[columns - 2], source = fields[columns - 1];
        execute('47', '47\n');
        const before = errors.length;
        const output = compile(source);
        assert.ok(output.includes(reason), name + ': expected diagnostic: ' + reason + ', got ' + output);
        assert.ok(!output.includes('(module'), name + ': must clear previous WAT');
        assert.equal(errors.length, before + 1, name + ': a type failure traps only this callback');
        execute('53', '53\n');
        refusals++;
      }
    }
    assert.equal(refusals, 61);
    console.log(`selfhost_browser_check: ${lines} oracle lines, 61 refusals and same-instance recovery passed`);
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
  }
}

check(path.resolve(process.argv[2] || '')).catch(error => { console.error(error); process.exit(1); });

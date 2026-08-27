// scripts/mere_parse_float.js — how a Mere `float_of_str` reads a string.
//
// ONE COPY, because there were two hosts and one of them was wrong.
// scripts/run_wasm.js had this function; scripts/run_http_server.js said in a
// comment that it reused run_wasm.js's env imports and in fact hand-copied
// them, using bare `parseFloat` instead. So the same program parsed floats one
// way under the CLI host and another under the HTTP host -- and when v0.1.277
// added `__lang_float_of_str_ok` to the refusal enumeration, only the copy that
// was maintained got it. The HTTP host then could not instantiate ANY Mere
// module at all, and no gate noticed, because no gate ran it.
//
// Returns {ok, value}: `ok` false means the string is not a float, which is a
// different answer from NaN (which IS one).

function mereParseFloat(raw) {
  const s = raw.trim().split("_").join("");
  if (s === "") return { ok: false, value: 0 };
  const m = /^([+-]?)(inf(inity)?|nan)$/i.exec(s);
  if (m) {
    if (/^nan$/i.test(m[2])) return { ok: true, value: NaN };
    return { ok: true, value: m[1] === "-" ? -Infinity : Infinity };
  }
  // hex floats: 0x1p3 is 8, and JS has no literal for them
  const h = /^([+-]?)0[xX]([0-9a-fA-F]*)(?:\.([0-9a-fA-F]*))?(?:[pP]([+-]?\d+))?$/.exec(s);
  if (h) {
    if (!h[2] && !h[3]) return { ok: false, value: 0 };
    let v = 0;
    for (const c of h[2] || "") v = v * 16 + parseInt(c, 16);
    let scale = 1 / 16;
    for (const c of h[3] || "") { v += parseInt(c, 16) * scale; scale /= 16; }
    if (h[4] !== undefined) v *= Math.pow(2, parseInt(h[4], 10));
    return { ok: true, value: h[1] === "-" ? -v : v };
  }
  if (!/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(s)) return { ok: false, value: 0 };
  const v = Number(s);
  return Number.isNaN(v) ? { ok: false, value: 0 } : { ok: true, value: v };
}

module.exports = { mereParseFloat };

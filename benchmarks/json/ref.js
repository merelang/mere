// json reference, Node. V8's JSON.parse.
const fs = require("fs");
const tree = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));

function walk(v) {
  if (v === null) return [1, 0, 0];
  if (typeof v === "boolean") return [1, v ? 1 : 0, 0];
  if (typeof v === "number") return [1, v, 0];
  if (typeof v === "string") return [1, 0, v.length];
  if (Array.isArray(v)) {
    let n = 1, i = 0, l = 0;
    for (const x of v) { const [a, b, c] = walk(x); n += a; i += b; l += c; }
    return [n, i, l];
  }
  let n = 1, i = 0, l = 0;
  for (const k of Object.keys(v)) {
    const [a, b, c] = walk(v[k]); n += a; i += b; l += c + k.length;
  }
  return [n, i, l];
}

const [nodes, ints, chars] = walk(tree);
console.log("nodes " + nodes);
console.log("ints " + ints);
console.log("strlen " + chars);

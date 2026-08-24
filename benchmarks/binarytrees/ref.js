// binarytrees reference, Node. Two-element arrays; null is a leaf.
function build(d) { return d === 0 ? null : [build(d - 1), build(d - 1)]; }
function check(t) { return t === null ? 1 : 1 + check(t[0]) + check(t[1]); }

const maxdepth = parseInt(process.argv[2] || "14", 10);
const longlived = build(maxdepth);
for (let d = 4; d <= maxdepth; d += 2) {
  const iters = 2 ** (maxdepth - d + 4);
  let acc = 0;
  for (let i = 0; i < iters; i++) acc += check(build(d));
  console.log(iters + " trees of depth " + d + " check " + acc);
}
console.log("long-lived tree of depth " + maxdepth + " check " + check(longlived));

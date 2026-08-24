// matmul reference, Node. JS arithmetic is strict IEEE-754 double; no fusion.
const n = parseInt(process.argv[2] || "128", 10);

function mk(seed) {
  const v = new Float64Array(n * n);
  let x = BigInt(seed);
  for (let i = 0; i < n * n; i++) {
    x = (1103515245n * x + 12345n) % 2147483648n;
    v[i] = Number(x % 2001n - 1000n) / 1000.0;
  }
  return v;
}

const a = mk(20260825), b = mk(77770707), c = new Float64Array(n * n);
for (let i = 0; i < n; i++)
  for (let j = 0; j < n; j++) {
    let acc = 0.0;
    for (let k = 0; k < n; k++) acc = acc + a[i * n + k] * b[k * n + j];
    c[i * n + j] = acc;
  }
let s = 0.0;
for (let i = 0; i < n * n; i++) s = s + c[i];
const buf = new DataView(new ArrayBuffer(8));
buf.setFloat64(0, s);
console.log("n " + n);
console.log("checksum " + buf.getUint32(0) + " " + buf.getUint32(4));

// churn reference, Node. Map; delete is O(1).
const n = parseInt(process.argv[2], 10);
const live = parseInt(process.argv[3], 10);
const pad = "------------------------------------------";
const m = new Map();
for (let i = 0; i < n; i++) {
  m.set("s" + i, i + pad);
  if (i >= live) m.delete("s" + (i - live));
}
let acc = 0;
for (let j = n - live; j < n; j++) acc += m.get("s" + j).length;
console.log("live " + m.size);
console.log("checksum " + acc);

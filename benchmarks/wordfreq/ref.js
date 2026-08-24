// wordfreq reference, Node. Map, the idiomatic answer.
const fs = require("fs");
const text = fs.readFileSync(process.argv[2], "utf8");
const counts = new Map();
let total = 0;
for (const w of text.split(/[ \n]/)) {
  if (w === "") continue;
  counts.set(w, (counts.get(w) || 0) + 1);
  total++;
}
const pairs = [...counts.entries()];
pairs.sort((a, b) => (b[1] !== a[1] ? b[1] - a[1] : a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
console.log("words " + total);
console.log("unique " + pairs.length);
for (const [w, c] of pairs.slice(0, 10)) console.log(w + " " + c);

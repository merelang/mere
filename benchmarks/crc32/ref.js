// crc32 reference, Node. Bitwise, no table, no library.
const fs = require("fs");
const buf = fs.readFileSync(process.argv[2]);
let crc = 0xFFFFFFFF;
for (let i = 0; i < buf.length; i++) {
  let c = (crc ^ buf[i]) >>> 0;
  for (let k = 0; k < 8; k++) c = (c & 1) === 1 ? ((c >>> 1) ^ 0xEDB88320) >>> 0 : c >>> 1;
  crc = c;
}
crc = (crc ^ 0xFFFFFFFF) >>> 0;
console.log("bytes " + buf.length);
console.log("crc32 " + crc);

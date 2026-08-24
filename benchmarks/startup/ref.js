// startup reference, Node.
const n = BigInt(process.argv[2] || "0");
console.log("startup " + (n * n + 1n));

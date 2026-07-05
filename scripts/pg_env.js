// scripts/pg_env.js — extern imports shared between run_wasm.js and
// run_http_server.js for programs that talk to Postgres from Mere.
//
// Groups three concerns that were previously duplicated between the two
// Node harnesses:
//   1. Synchronous TCP transport (worker_thread + SAB + Atomics.wait)
//   2. Byte-buffer primitives — mem_alloc/set/get, str_ptr, mem_to_str
//   3. Crypto helpers for SCRAM / URL parsing — pbkdf2, hmac, base64, XOR
//
// Usage:
//   const { makePgEnv, PG_TCP_STATE } = require("./pg_env.js");
//   ...
//   const pgEnv = makePgEnv({ getMemory, bumpAlloc });
//   const env = { ...pgEnv, ...customEnv };
//
// `getMemory` is a zero-arg function returning the current `WebAssembly.
// Memory.buffer` (memory may grow during execution). `bumpAlloc(n)`
// returns a fresh linear-memory offset with room for `n` bytes.

'use strict';

const path = require('path');
const { Worker } = require('worker_threads');

const TCP_DATA_OFFSET = 32;
const TCP_BUF_BYTES = 1 << 20;  // 1 MiB shared window; big enough for typical DB frames
const TCP_SAB = new SharedArrayBuffer(TCP_DATA_OFFSET + TCP_BUF_BYTES);
const tcpCtrl = new Int32Array(TCP_SAB, 0, 8);
const tcpData = new Uint8Array(TCP_SAB, TCP_DATA_OFFSET);
const TCP_OP = {
  CONNECT: 1, WRITE: 2, READ: 3, CLOSE: 4, SET_TIMEOUT: 5,
  STARTTLS: 6, STARTTLS_VERIFIED: 7,
};
let tcpWorker = null;

function tcpEnsureWorker() {
  if (tcpWorker) return;
  const workerPath = path.join(__dirname, 'tcp_worker.js');
  tcpWorker = new Worker(workerPath, {
    workerData: { sab: TCP_SAB, dataOffset: TCP_DATA_OFFSET },
  });
  tcpWorker.unref();  // don't keep the parent process alive on this alone
}

function tcpCall(op, arg1, arg2) {
  tcpEnsureWorker();
  Atomics.store(tcpCtrl, 1, op);
  Atomics.store(tcpCtrl, 2, arg1 | 0);
  Atomics.store(tcpCtrl, 3, arg2 | 0);
  Atomics.store(tcpCtrl, 0, 1);
  tcpWorker.postMessage(0);
  Atomics.wait(tcpCtrl, 0, 1);
  Atomics.store(tcpCtrl, 0, 0);
  return Atomics.load(tcpCtrl, 4);
}

function makePgEnv({ getMemory, bumpAlloc }) {
  // readCStr is trivially built from getMemory, so both harnesses share
  // the same NUL-scan without needing to pass it in.
  const readCStr = (ptr) => {
    const bytes = new Uint8Array(getMemory());
    let end = ptr;
    while (end < bytes.length && bytes[end] !== 0) end++;
    return Buffer.from(bytes.subarray(ptr, end)).toString('utf8');
  };
  const writeStr = (s) => {
    const bytes = Buffer.from(s + '\0', 'utf8');
    const ptr = bumpAlloc(bytes.length);
    new Uint8Array(getMemory()).set(bytes, ptr);
    return ptr;
  };

  return {
    // ---- Sync TCP -------------------------------------------------------
    tcp_connect: (hostPtr, port) => {
      const host = readCStr(hostPtr);
      const bytes = Buffer.from(host, 'utf8');
      tcpData.set(bytes, 0);
      return tcpCall(TCP_OP.CONNECT, bytes.length, port | 0) | 0;
    },
    tcp_write: (fd, bufPtr, len) => {
      const src = new Uint8Array(getMemory(), bufPtr, len);
      tcpData.set(src, 0);
      return tcpCall(TCP_OP.WRITE, fd | 0, len | 0) | 0;
    },
    tcp_read: (fd, bufPtr, cap) => {
      const capped = Math.min(cap | 0, TCP_BUF_BYTES);
      const n = tcpCall(TCP_OP.READ, fd | 0, capped) | 0;
      if (n > 0) {
        const dst = new Uint8Array(getMemory(), bufPtr, n);
        dst.set(tcpData.subarray(0, n));
      }
      return n;
    },
    tcp_close: (fd) => { tcpCall(TCP_OP.CLOSE, fd | 0, 0); return 0; },
    tcp_set_timeout: (fd, ms) => { tcpCall(TCP_OP.SET_TIMEOUT, fd | 0, ms | 0); return 0; },
    // tcp_starttls(fd, sni_host: str) -> int (0 = success, -1 = handshake
    //   failed). Upgrades an already-established plain TCP connection to
    //   TLS in place. Used by pg / mysql SSL negotiation.
    tcp_starttls: (fd, hostPtr) => {
      const host = readCStr(hostPtr);
      const bytes = Buffer.from(host, 'utf8');
      tcpData.set(bytes, 0);
      return tcpCall(TCP_OP.STARTTLS, fd | 0, bytes.length) | 0;
    },

    // tcp_starttls_verified(fd, sni_host: str, ca_pem: str) -> int
    //   Same as tcp_starttls but with cert-chain verification enabled
    //   (`rejectUnauthorized: true`). If `ca_pem` is empty, Node falls
    //   back to its built-in root store; otherwise the passed PEM is
    //   the sole accepted trust anchor.
    tcp_starttls_verified: (fd, hostPtr, caPtr) => {
      const host = readCStr(hostPtr);
      const ca = readCStr(caPtr);
      const hostBytes = Buffer.from(host, 'utf8');
      const caBytes = Buffer.from(ca, 'utf8');
      tcpData.set(hostBytes, 0);
      tcpData.set(caBytes, hostBytes.length);
      const packed = (hostBytes.length & 0xffff) | ((caBytes.length & 0xffff) << 16);
      return tcpCall(TCP_OP.STARTTLS_VERIFIED, fd | 0, packed) | 0;
    },

    // ---- Byte-buffer primitives -----------------------------------------
    str_ptr: (ptr) => ptr,
    mem_alloc: (n) => bumpAlloc(n | 0),
    mem_set_u8: (ptr, off, b) => {
      new Uint8Array(getMemory())[(ptr | 0) + (off | 0)] = b & 0xff;
      return 0;
    },
    mem_get_u8: (ptr, off) => {
      return new Uint8Array(getMemory())[(ptr | 0) + (off | 0)] | 0;
    },
    mem_set_u32be: (ptr, off, val) => {
      new DataView(getMemory()).setUint32((ptr | 0) + (off | 0), val >>> 0, false);
      return 0;
    },
    mem_get_u32be: (ptr, off) => {
      return new DataView(getMemory()).getInt32((ptr | 0) + (off | 0), false);
    },
    mem_set_u16be: (ptr, off, val) => {
      new DataView(getMemory()).setUint16((ptr | 0) + (off | 0), val & 0xffff, false);
      return 0;
    },
    mem_get_u16be: (ptr, off) => {
      return new DataView(getMemory()).getUint16((ptr | 0) + (off | 0), false);
    },
    // Little-endian variants — MySQL / SQLite / most native protocols
    // outside the PG family use these.
    mem_set_u16le: (ptr, off, val) => {
      new DataView(getMemory()).setUint16((ptr | 0) + (off | 0), val & 0xffff, true);
      return 0;
    },
    mem_get_u16le: (ptr, off) => {
      return new DataView(getMemory()).getUint16((ptr | 0) + (off | 0), true);
    },
    mem_set_u32le: (ptr, off, val) => {
      new DataView(getMemory()).setUint32((ptr | 0) + (off | 0), val >>> 0, true);
      return 0;
    },
    mem_get_u32le: (ptr, off) => {
      return new DataView(getMemory()).getInt32((ptr | 0) + (off | 0), true);
    },
    mem_copy_str: (dst, off, srcPtr) => {
      const bytes = new Uint8Array(getMemory());
      let src = srcPtr | 0;
      let d = (dst | 0) + (off | 0);
      while (bytes[src] !== 0) bytes[d++] = bytes[src++];
      return d - (dst | 0);
    },
    mem_to_str: (ptr, len) => {
      const n = len | 0;
      const dst = bumpAlloc(n + 1);
      const bytes = new Uint8Array(getMemory());
      bytes.copyWithin(dst, ptr | 0, (ptr | 0) + n);
      bytes[dst + n] = 0;
      return dst;
    },

    // ---- Crypto ---------------------------------------------------------
    // SHA-1 — MySQL's `mysql_native_password` auth needs it. Modern
    // stacks prefer SHA-256, but the deprecated hash still ships with
    // every MySQL server we're likely to touch.
    sha1_hex: (ptr) => {
      const s = readCStr(ptr);
      return writeStr(require('crypto').createHash('sha1').update(s).digest('hex'));
    },
    sha1_of_hex: (ptr) => {
      const h = Buffer.from(readCStr(ptr), 'hex');
      return writeStr(require('crypto').createHash('sha1').update(h).digest('hex'));
    },
    sha256_hex: (ptr) => {
      const s = readCStr(ptr);
      return writeStr(require('crypto').createHash('sha256').update(s).digest('hex'));
    },
    sha256_of_hex: (ptr) => {
      const h = Buffer.from(readCStr(ptr), 'hex');
      return writeStr(require('crypto').createHash('sha256').update(h).digest('hex'));
    },
    hmac_sha256_hex: (keyPtr, msgPtr) => {
      const key = readCStr(keyPtr);
      const msg = readCStr(msgPtr);
      return writeStr(require('crypto').createHmac('sha256', key).update(msg).digest('hex'));
    },
    hmac_sha256_hex_hex: (keyPtr, msgPtr) => {
      const key = Buffer.from(readCStr(keyPtr), 'hex');
      const msg = Buffer.from(readCStr(msgPtr), 'hex');
      return writeStr(require('crypto').createHmac('sha256', key).update(msg).digest('hex'));
    },
    hmac_sha256_hex_str: (keyPtr, msgPtr) => {
      const key = Buffer.from(readCStr(keyPtr), 'hex');
      const msg = readCStr(msgPtr);
      return writeStr(require('crypto').createHmac('sha256', key).update(msg).digest('hex'));
    },
    pbkdf2_sha256_hex: (pwPtr, saltPtr, iters, keylen) => {
      const password = readCStr(pwPtr);
      const salt = Buffer.from(readCStr(saltPtr), 'hex');
      const out = require('crypto').pbkdf2Sync(password, salt, iters | 0, keylen | 0, 'sha256');
      return writeStr(out.toString('hex'));
    },
    base64_encode_hex: (ptr) => {
      return writeStr(Buffer.from(readCStr(ptr), 'hex').toString('base64'));
    },
    base64_decode_to_hex: (ptr) => {
      return writeStr(Buffer.from(readCStr(ptr), 'base64').toString('hex'));
    },
    // Standard-alphabet base64 (+/, padded) directly from/to utf8 strs.
    // The `_hex` variants above accept raw-byte input via a hex-string
    // detour so they can round-trip binary. This pair skips the hex
    // step for the common case where input/output are utf8 text —
    // e.g. HTTP Basic Auth's `dXNlcjpwYXNz` <-> `user:pass`.
    base64_encode: (ptr) => {
      return writeStr(Buffer.from(readCStr(ptr), 'utf8').toString('base64'));
    },
    base64_decode: (ptr) => {
      return writeStr(Buffer.from(readCStr(ptr), 'base64').toString('utf8'));
    },
    random_hex: (n) => {
      return writeStr(require('crypto').randomBytes(n | 0).toString('hex'));
    },
    // gen_request_id — 16-hex random request/session id. Same shape
    // as the http-server-specific version previously defined only
    // in run_http_server.js; hoisted here so CLI Mere programs
    // (running under run_wasm.js) that use it — e.g. redis_lock's
    // fencing tokens, session ids in test harnesses — link cleanly.
    gen_request_id: () => {
      return writeStr(require('crypto').randomBytes(8).toString('hex'));
    },
    random_b64: (n) => {
      return writeStr(require('crypto').randomBytes(n | 0).toString('base64'));
    },
    hex_xor: (aPtr, bPtr) => {
      const a = Buffer.from(readCStr(aPtr), 'hex');
      const b = Buffer.from(readCStr(bPtr), 'hex');
      if (a.length !== b.length) return writeStr('');
      const r = Buffer.alloc(a.length);
      for (let i = 0; i < a.length; i++) r[i] = a[i] ^ b[i];
      return writeStr(r.toString('hex'));
    },

    // bytes_to_hex(s: str) -> hex — hex-encode the UTF-8 bytes of s.
    // Needed for values that were built as text but must reach an extern
    // that only knows how to speak hex (RSA, hex_xor on non-digest data,
    // …).
    bytes_to_hex: (ptr) => {
      return writeStr(Buffer.from(readCStr(ptr), 'utf8').toString('hex'));
    },

    // bytes_to_hex_len(ptr, len) -> str — length-aware companion to
    //   bytes_to_hex. Reads exactly `len` bytes starting at `ptr` and
    //   hex-encodes the result, regardless of any interior NUL bytes.
    //   Used by Redis's binary-safe read path (redis_bulk_bytes hands
    //   the ptr + len; this turns them into a NUL-free str).
    bytes_to_hex_len: (ptr, len) => {
      const src = new Uint8Array(getMemory(), ptr | 0, len | 0);
      return writeStr(Buffer.from(src).toString('hex'));
    },

    // crc16_xmodem(s: str) -> int
    //   XMODEM CRC16 over the UTF-8 bytes of `s`. Used by the Redis
    //   Cluster slot calculation (slot = crc16(key) & 0x3FFF, or 16383).
    //   Poly 0x1021, init 0, no reflection, no xor-out.
    crc16_xmodem: (ptr) => {
      const s = readCStr(ptr);
      const bytes = Buffer.from(s, 'utf8');
      let crc = 0;
      for (let i = 0; i < bytes.length; i++) {
        crc ^= bytes[i] << 8;
        for (let j = 0; j < 8; j++) {
          crc = (crc & 0x8000) ? ((crc << 1) ^ 0x1021) : (crc << 1);
          crc &= 0xffff;
        }
      }
      return crc;
    },

    // bytes_from_hex_alloc(hex: str) -> int (raw pointer)
    //   Decode a hex string into raw bytes on the Mere heap. Returns
    //   the pointer; the caller already knows the byte count (=
    //   str_len(hex) / 2), so a single-int return keeps the extern
    //   simple.
    bytes_from_hex_alloc: (hexPtr) => {
      const hex = readCStr(hexPtr);
      const bytes = Buffer.from(hex, 'hex');
      const dst = bumpAlloc(bytes.length);
      new Uint8Array(getMemory()).set(bytes, dst);
      return dst;
    },

    // bytes_cycle_xor_hex(bytes_hex, key_hex) -> hex — XOR `bytes` with
    // a copy of `key` that repeats to match its length. Used by MySQL's
    // caching_sha2_password full-auth path to obfuscate the cleartext
    // password before RSA encryption.
    bytes_cycle_xor_hex: (bytesPtr, keyPtr) => {
      const bytes = Buffer.from(readCStr(bytesPtr), 'hex');
      const key = Buffer.from(readCStr(keyPtr), 'hex');
      if (key.length === 0) return writeStr(bytes.toString('hex'));
      const r = Buffer.alloc(bytes.length);
      for (let i = 0; i < bytes.length; i++) r[i] = bytes[i] ^ key[i % key.length];
      return writeStr(r.toString('hex'));
    },

    // rsa_encrypt_oaep_sha1(pem: str, data_hex: str) -> hex
    //   Encrypts `data` with the RSA public key parsed from `pem`,
    //   using OAEP padding with SHA-1 (MySQL's choice for the
    //   caching_sha2_password full-auth ciphertext).
    rsa_encrypt_oaep_sha1: (pemPtr, dataPtr) => {
      const crypto = require('crypto');
      const pem = readCStr(pemPtr);
      const data = Buffer.from(readCStr(dataPtr), 'hex');
      const encrypted = crypto.publicEncrypt(
        { key: pem, padding: crypto.constants.RSA_PKCS1_OAEP_PADDING, oaepHash: 'sha1' },
        data,
      );
      return writeStr(encrypted.toString('hex'));
    },
  };
}

module.exports = { makePgEnv };

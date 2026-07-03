// scripts/tcp_worker.js — synchronous TCP transport for Wasm-hosted Mere.
//
// Runs in a worker_threads.Worker. The main thread's `tcp_*` externs
// write a request into a SharedArrayBuffer, notify this worker, and
// Atomics.wait on the response slot. This worker owns the actual
// net.Socket handles (which are async) and copies the results back
// into the SAB so the main thread's Atomics.wait can unblock.
//
// Message flow (SAB layout — see scripts/run_wasm.js for offsets):
//   ctrl[0]      REQ_STATE   0=idle, 1=request pending, 2=response ready
//   ctrl[1]      OP          operation id (CONNECT / WRITE / READ / …)
//   ctrl[2]      FD          per-op arg 1 (socket fd or connect port)
//   ctrl[3]      ARG2        per-op arg 2 (length, timeout ms, …)
//   ctrl[4]      RESULT      response payload — return code or byte count
//   data[0..N]               per-op payload (host string, buffer, …)
//
// The worker never allocates a new SAB; the main thread creates it
// once at boot and passes it via workerData. Requests are strictly
// serialized (one in flight at a time) — parallel calls from Mere
// would need per-op SABs, which the current single-threaded Wasm
// execution model doesn't require.

'use strict';

const net = require('net');
const { parentPort, workerData } = require('worker_threads');

const OP = {
  CONNECT: 1,
  WRITE: 2,
  READ: 3,
  CLOSE: 4,
  SET_TIMEOUT: 5,
};

const { sab, dataOffset } = workerData;
const ctrl = new Int32Array(sab, 0, 8);
const dataView = new Uint8Array(sab, dataOffset);

// fd -> { socket, rxBuf: Buffer[], rxLen, closed, err }
const sockets = new Map();
let nextFd = 1;

function decodeUtf8(offset, len) {
  return Buffer.from(dataView.buffer, dataView.byteOffset + offset, len).toString('utf8');
}

function respond(status, resultLen) {
  Atomics.store(ctrl, 4, status);
  if (resultLen !== undefined) Atomics.store(ctrl, 3, resultLen);
  Atomics.store(ctrl, 0, 2);
  Atomics.notify(ctrl, 0);
}

function doConnect(hostLen, port) {
  const host = decodeUtf8(0, hostLen);
  const fd = nextFd++;
  // allowHalfOpen: peer FIN (nc, some HTTP proxies, ...) shouldn't auto-close
  // our write side. DB clients terminate explicitly via tcp_close.
  const socket = net.createConnection({ host, port, allowHalfOpen: true });
  const entry = { socket, rxBuf: [], rxLen: 0, closed: false, err: null, pendingRead: null };
  sockets.set(fd, entry);

  socket.on('data', (chunk) => {
    entry.rxBuf.push(chunk);
    entry.rxLen += chunk.length;
    if (entry.pendingRead) {
      const cb = entry.pendingRead;
      entry.pendingRead = null;
      cb();
    }
  });
  socket.on('error', (e) => {
    entry.err = e;
    entry.closed = true;
    if (entry.pendingConnect) {
      const cb = entry.pendingConnect;
      entry.pendingConnect = null;
      cb();
    }
    if (entry.pendingRead) {
      const cb = entry.pendingRead;
      entry.pendingRead = null;
      cb();
    }
  });
  socket.on('close', () => {
    entry.closed = true;
    if (entry.pendingRead) {
      const cb = entry.pendingRead;
      entry.pendingRead = null;
      cb();
    }
  });
  // socket.setTimeout fires this after N ms of idle read. Node's default
  // is to leave the socket open — we resolve the pending read as "0
  // bytes" so pg_wait_notify can distinguish a timeout from a real EOF
  // (which would set entry.closed).
  socket.on('timeout', () => {
    if (entry.pendingRead) {
      const cb = entry.pendingRead;
      entry.pendingRead = null;
      cb();
    }
  });

  entry.pendingConnect = () => {
    if (entry.err) respond(-1, 0);
    else respond(fd, 0);
  };
  socket.once('connect', () => {
    const cb = entry.pendingConnect;
    if (cb) { entry.pendingConnect = null; cb(); }
  });
}

function doWrite(fd, len) {
  const entry = sockets.get(fd);
  if (!entry || entry.closed) { respond(-1, 0); return; }
  const chunk = Buffer.from(dataView.buffer, dataView.byteOffset, len);
  // Copy — sendMessage may reclaim SAB slot before OS flush completes.
  const copy = Buffer.from(chunk);
  entry.socket.write(copy, (err) => {
    if (err) respond(-1, 0);
    else respond(len, 0);
  });
}

function drainRx(entry, cap) {
  const want = Math.min(cap, entry.rxLen);
  if (want === 0) return 0;
  let filled = 0;
  while (filled < want && entry.rxBuf.length > 0) {
    const head = entry.rxBuf[0];
    const take = Math.min(head.length, want - filled);
    dataView.set(head.subarray(0, take), filled);
    if (take === head.length) entry.rxBuf.shift();
    else entry.rxBuf[0] = head.subarray(take);
    filled += take;
  }
  entry.rxLen -= filled;
  return filled;
}

function doRead(fd, cap) {
  const entry = sockets.get(fd);
  if (!entry) { respond(-1, 0); return; }
  if (entry.rxLen > 0) {
    const n = drainRx(entry, cap);
    respond(n, n);
    return;
  }
  if (entry.closed) { respond(0, 0); return; }
  entry.pendingRead = () => {
    if (entry.rxLen > 0) {
      const n = drainRx(entry, cap);
      respond(n, n);
    } else if (entry.err) {
      respond(-1, 0);
    } else {
      respond(0, 0);  // EOF
    }
  };
}

function doClose(fd) {
  const entry = sockets.get(fd);
  if (entry) {
    try { entry.socket.destroy(); } catch (_) {}
    sockets.delete(fd);
  }
  respond(0, 0);
}

function doSetTimeout(fd, ms) {
  const entry = sockets.get(fd);
  if (entry) entry.socket.setTimeout(ms);
  respond(0, 0);
}

parentPort.on('message', () => {
  const op = Atomics.load(ctrl, 1);
  const arg1 = Atomics.load(ctrl, 2);
  const arg2 = Atomics.load(ctrl, 3);
  try {
    switch (op) {
      case OP.CONNECT:     doConnect(arg1, arg2); break;
      case OP.WRITE:       doWrite(arg1, arg2); break;
      case OP.READ:        doRead(arg1, arg2); break;
      case OP.CLOSE:       doClose(arg1); break;
      case OP.SET_TIMEOUT: doSetTimeout(arg1, arg2); break;
      default:             respond(-1, 0);
    }
  } catch (e) {
    respond(-1, 0);
  }
});

// scripts/sse_redis_bridge.js — bridge Redis pubsub → SSE broadcast.
//
// Turns a Mere HTTP server into one instance of a multi-process SSE
// deployment: every instance subscribes to the same Redis channel,
// so when instance A publishes a message, both A and B fan it out
// to their local SSE clients.
//
// Architecture:
//
//   POST /api/msg (handler on A)
//     └─ redis_publish "chat" payload      (goes to redis via pg_env)
//                    │
//                    ▼
//              redis server
//                    │
//         ┌──────────┴──────────┐
//         ▼                     ▼
//    subscriber on A       subscriber on B
//         │                     │
//    broadcast("chat",p)   broadcast("chat",p)
//         │                     │
//    A's SSE clients       B's SSE clients
//
// The subscribe socket lives entirely in JS (async, uses Node's
// non-blocking net.Socket). Mere's own sync tcp is not involved,
// because the http_serve loop can't yield to a Mere-side subscriber
// coroutine — but Node's event loop happily interleaves the socket
// callback with everything else.
//
// Extern surface (see contrib/http/sse.mere):
//
//   sse_bridge_from_redis channel host port -> unit
//     Fire-and-forget. Spawns (or reuses) a persistent RESP2
//     subscriber on the given Redis host:port and forwards every
//     `message`-shaped reply on `channel` to the SSE broadcast for
//     the same channel name. Auto-reconnects with a 1s backoff on
//     any socket error / close.
//
// Only handles the plain RESP2 `SUBSCRIBE` case — no pattern subs,
// no auth, no TLS. Enough for the pubsub-chat demo; graduate to
// the Mere-side redis_pubsub_run_forever for anything richer that
// runs alongside a real event loop (e.g. worker processes).

const net = require("net");

function makeSseRedisBridge({ broadcast, readCStr }) {
  // channel-string → socket (or "connecting" placeholder). Only one
  // subscriber per channel — subsequent calls are idempotent.
  const active = new Map();

  const parseRespReply = (buf) => {
    // Returns { value, rest } or null if the buffer is incomplete.
    // Only supports arrays of bulk strings / simple strings / ints —
    // the shape pubsub delivers on the wire.
    if (buf.length === 0) return null;
    const type = String.fromCharCode(buf[0]);
    if (type === "*") {
      const eol = buf.indexOf("\r\n");
      if (eol < 0) return null;
      const n = parseInt(buf.slice(1, eol).toString("ascii"), 10);
      let i = eol + 2;
      const items = [];
      for (let k = 0; k < n; k++) {
        const one = parseRespReply(buf.slice(i));
        if (!one) return null;
        items.push(one.value);
        i = buf.length - one.rest.length;
      }
      return { value: items, rest: buf.slice(i) };
    }
    if (type === "$") {
      const eol = buf.indexOf("\r\n");
      if (eol < 0) return null;
      const len = parseInt(buf.slice(1, eol).toString("ascii"), 10);
      if (len < 0) return { value: null, rest: buf.slice(eol + 2) };
      const end = eol + 2 + len + 2;
      if (buf.length < end) return null;
      return {
        value: buf.slice(eol + 2, eol + 2 + len).toString("utf8"),
        rest: buf.slice(end),
      };
    }
    if (type === "+" || type === "-") {
      const eol = buf.indexOf("\r\n");
      if (eol < 0) return null;
      return {
        value: buf.slice(1, eol).toString("utf8"),
        rest: buf.slice(eol + 2),
      };
    }
    if (type === ":") {
      const eol = buf.indexOf("\r\n");
      if (eol < 0) return null;
      return {
        value: parseInt(buf.slice(1, eol).toString("ascii"), 10),
        rest: buf.slice(eol + 2),
      };
    }
    return null;
  };

  const startSubscriber = (channel, host, port) => {
    let buf = Buffer.alloc(0);
    const socket = net.createConnection({ host, port });
    active.set(channel, socket);

    socket.on("connect", () => {
      const nameBytes = Buffer.byteLength(channel, "utf8");
      const cmd = `*2\r\n$9\r\nSUBSCRIBE\r\n$${nameBytes}\r\n${channel}\r\n`;
      socket.write(cmd);
    });

    socket.on("data", (chunk) => {
      buf = Buffer.concat([buf, chunk]);
      while (true) {
        const parsed = parseRespReply(buf);
        if (!parsed) break;
        buf = parsed.rest;
        const v = parsed.value;
        // `["message", channel, payload]` is the delivery shape.
        // Everything else (subscribe confirmations, pongs) is
        // ignored — the bridge is push-only.
        if (Array.isArray(v) && v.length === 3 && v[0] === "message") {
          try {
            broadcast(v[1], v[2]);
          } catch (e) {
            console.error("sse_redis_bridge: broadcast threw", e);
          }
        }
      }
    });

    const reconnect = () => {
      active.delete(channel);
      setTimeout(() => startSubscriber(channel, host, port), 1000);
    };
    socket.on("error", (e) => {
      // Don't spam the log — first failure is enough context.
      if (!socket._bridgeErrored) {
        console.error(`sse_redis_bridge: ${channel}@${host}:${port} error:`, e.message);
        socket._bridgeErrored = true;
      }
      try { socket.destroy(); } catch (_) {}
      reconnect();
    });
    socket.on("close", () => {
      if (!socket._bridgeErrored) reconnect();
    });
  };

  return {
    sse_bridge_from_redis: (channelPtr, hostPtr, port) => {
      const channel = readCStr(channelPtr);
      const host = readCStr(hostPtr);
      if (active.has(channel)) return 0;   // idempotent
      startSubscriber(channel, host, port | 0);
      return 0;
    },
  };
}

module.exports = { makeSseRedisBridge };

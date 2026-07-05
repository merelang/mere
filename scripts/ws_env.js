// scripts/ws_env.js — WebSocket hub for contrib/http.
//
// Speaks RFC 6455 well enough for text-frame broadcast + auto-relay
// chat:
//
//   Handshake       GET /ws/<channel>  Upgrade: websocket
//                     → 101 + Sec-WebSocket-Accept
//                       (base64(sha1(client_key + magic)))
//
//   Server → client `ws_broadcast(channel, payload)` writes one
//                   text frame (opcode 0x1, unmasked, FIN=1) to
//                   every socket currently subscribed to channel.
//
//   Client → other  Frames received from a client (masked, per
//                   RFC 6455) are decoded and rebroadcast to every
//                   OTHER socket on the same channel — the glue
//                   acts as a hub. Mere doesn't see individual
//                   messages; it just publishes when it has news.
//
//   Close           Peer close frame → glue writes matching close
//                   frame + destroys the socket.
//
// Not supported (deferred):
//   - Binary frames (opcode 0x2). Received binary is dropped.
//   - Fragmented frames (FIN=0 continuation). We assume every frame
//     is a complete message.
//   - Payload > 2^31 bytes. Realistic browser messages are < 1 MiB.
//   - Per-connection state / auth callbacks into Mere.
//
// Factory shape mirrors makeHttpFetchEnv:
//
//   const { extras, tryUpgrade } = makeWsEnv({ readCStr });
//   Object.assign(env, extras);
//   // In the HTTP upgrade handler:
//   if (tryUpgrade(req, socket, head)) return;

const crypto = require("crypto");
const WS_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

function makeWsEnv({ readCStr }) {
  // channel → Set<socket>. Sockets are net.Sockets (post-upgrade).
  const channels = new Map();

  const encodeTextFrame = (payload) => {
    const body = Buffer.from(payload, "utf8");
    const len = body.length;
    let header;
    if (len < 126) {
      header = Buffer.from([0x81, len]);
    } else if (len < 65536) {
      header = Buffer.alloc(4);
      header[0] = 0x81;
      header[1] = 126;
      header.writeUInt16BE(len, 2);
    } else {
      header = Buffer.alloc(10);
      header[0] = 0x81;
      header[1] = 127;
      // Node.js supports writeBigUInt64BE, but every realistic payload
      // fits in the low 32 bits — use two writes for portability.
      header.writeUInt32BE(0, 2);
      header.writeUInt32BE(len, 6);
    }
    return Buffer.concat([header, body]);
  };

  const broadcastText = (channel, payload, exclude) => {
    const set = channels.get(channel);
    if (!set) return;
    const frame = encodeTextFrame(payload);
    for (const sock of set) {
      if (sock === exclude) continue;
      try { sock.write(frame); } catch (_) { /* client gone */ }
    }
  };

  // Frame reader for client → server. Client frames are ALWAYS masked
  // per RFC 6455. Returns { payload, opcode, rest } or null if the
  // buffer doesn't yet contain a full frame.
  const parseClientFrame = (buf) => {
    if (buf.length < 2) return null;
    const b0 = buf[0];
    const b1 = buf[1];
    const fin = (b0 & 0x80) !== 0;
    const opcode = b0 & 0x0f;
    const masked = (b1 & 0x80) !== 0;
    if (!masked) {
      // Spec says the server MUST close the connection on an unmasked
      // client frame. Signal via null + drop caller responsibility.
      return { protocolError: true };
    }
    let len = b1 & 0x7f;
    let offset = 2;
    if (len === 126) {
      if (buf.length < 4) return null;
      len = buf.readUInt16BE(2);
      offset = 4;
    } else if (len === 127) {
      if (buf.length < 10) return null;
      // Skip the top 4 bytes — assume payload < 2^32.
      len = buf.readUInt32BE(6);
      offset = 10;
    }
    if (buf.length < offset + 4 + len) return null;
    const mask = buf.slice(offset, offset + 4);
    const body = Buffer.alloc(len);
    for (let i = 0; i < len; i++) body[i] = buf[offset + 4 + i] ^ mask[i & 3];
    return {
      fin,
      opcode,
      payload: body,
      rest: buf.slice(offset + 4 + len),
    };
  };

  const writeCloseFrame = (sock, code) => {
    const c = code || 1000;
    const buf = Buffer.from([0x88, 0x02, (c >> 8) & 0xff, c & 0xff]);
    try { sock.write(buf); } catch (_) {}
  };

  // Called by http.glue.js on an 'upgrade' event. Returns true if we
  // handled the request (i.e. the URL matched /ws/<channel>).
  const tryUpgrade = (req, socket, head) => {
    if (!req.url || !req.url.startsWith("/ws/")) return false;
    const channel = req.url.slice("/ws/".length).split("?")[0];
    const key = req.headers["sec-websocket-key"];
    if (!key) {
      socket.destroy();
      return true;
    }
    const accept = crypto
      .createHash("sha1")
      .update(key + WS_MAGIC)
      .digest("base64");
    const respLines = [
      "HTTP/1.1 101 Switching Protocols",
      "Upgrade: websocket",
      "Connection: Upgrade",
      "Sec-WebSocket-Accept: " + accept,
      "",
      "",
    ];
    socket.write(respLines.join("\r\n"));
    socket.setNoDelay(true);

    let set = channels.get(channel);
    if (!set) { set = new Set(); channels.set(channel, set); }
    set.add(socket);

    let readBuf = head && head.length ? Buffer.from(head) : Buffer.alloc(0);

    const cleanup = () => {
      const s = channels.get(channel);
      if (s) {
        s.delete(socket);
        if (s.size === 0) channels.delete(channel);
      }
    };

    socket.on("data", (chunk) => {
      readBuf = Buffer.concat([readBuf, chunk]);
      while (true) {
        const frame = parseClientFrame(readBuf);
        if (!frame) break;
        if (frame.protocolError) {
          writeCloseFrame(socket, 1002);
          socket.destroy();
          cleanup();
          return;
        }
        readBuf = frame.rest;
        switch (frame.opcode) {
          case 0x1: {
            // Text — auto-relay to peers on this channel.
            const text = frame.payload.toString("utf8");
            broadcastText(channel, text, socket);
            break;
          }
          case 0x8: {
            // Close. Echo back and destroy.
            writeCloseFrame(socket, 1000);
            socket.destroy();
            cleanup();
            return;
          }
          case 0x9: {
            // Ping — reply with pong (opcode 0xa) carrying same payload.
            const pongHdr = Buffer.from([0x8a, frame.payload.length]);
            socket.write(Buffer.concat([pongHdr, frame.payload]));
            break;
          }
          case 0xa: {
            // Pong — no reply.
            break;
          }
          default:
            // Binary / continuation / reserved — silently drop.
            break;
        }
      }
    });

    socket.on("error", cleanup);
    socket.on("close", cleanup);
    return true;
  };

  const extras = {
    // ws_broadcast(channel, payload) — send one text frame to every
    // connected client on `channel`. From Mere via
    // `extern fn ws_broadcast: str -> str -> unit`.
    ws_broadcast: (channelPtr, payloadPtr) => {
      broadcastText(readCStr(channelPtr), readCStr(payloadPtr), null);
    },
    // ws_client_count(channel) — how many sockets are currently
    // subscribed. Useful for a "0 listeners → skip work" fast-path.
    ws_client_count: (channelPtr) => {
      const set = channels.get(readCStr(channelPtr));
      return set ? set.size : 0;
    },
  };

  return { extras, tryUpgrade };
}

module.exports = { makeWsEnv };

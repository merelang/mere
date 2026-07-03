// Mere chat frontend — EventSource for receive, fetch for send.

const $ = (id) => document.getElementById(id);
const log = (msg) => {
  const el = $("log");
  el.textContent += msg + "\n";
  el.scrollTop = el.scrollHeight;
};

const escapeHtml = (s) =>
  String(s).replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[c]));

const setStatus = (label, cls) => {
  const el = $("status");
  el.textContent = label;
  el.className = cls || "";
};

const seen = new Set();
function appendMessage(msg) {
  if (seen.has(msg.id)) return;
  seen.add(msg.id);
  const li = document.createElement("li");
  const when = new Date(parseInt(msg.ts, 10) * 1000).toLocaleTimeString();
  li.innerHTML =
    `<span class="author">${escapeHtml(msg.author)}</span>` +
    `<span class="text">${escapeHtml(msg.text)}</span>` +
    `<span class="ts">${when}</span>`;
  $("messages").appendChild(li);
  li.scrollIntoView({ block: "end", behavior: "smooth" });
}

async function bootstrap() {
  const resp = await fetch("/api/messages");
  if (resp.status !== 200) { log("bootstrap GET /api/messages failed: " + resp.status); return; }
  const rows = await resp.json();
  for (const m of rows) appendMessage(m);
  log(`bootstrapped ${rows.length} message(s)`);
}

function connect() {
  const es = new EventSource("/sse/chat");
  es.onopen = () => { setStatus("live · listening", "live"); log("SSE open"); };
  es.onerror = () => { setStatus("disconnected · retrying", "dead"); log("SSE error"); };
  es.onmessage = (e) => {
    try {
      const msg = JSON.parse(e.data);
      appendMessage(msg);
    } catch (err) {
      log("bad SSE payload: " + e.data);
    }
  };
}

$("compose").addEventListener("submit", async (e) => {
  e.preventDefault();
  const author = $("author").value.trim() || "anon";
  const text = $("text").value;
  if (!text.trim()) return;
  const resp = await fetch("/api/messages", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ author, text }),
  });
  $("text").value = "";
  log(`POST /api/messages → ${resp.status}`);
});

(async () => {
  await bootstrap();
  connect();
})();

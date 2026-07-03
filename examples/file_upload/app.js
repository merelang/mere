// Mere file upload frontend — <form> submits FormData, results
// listed as clickable download links.

const $ = (id) => document.getElementById(id);
const log = (msg) => {
  const el = $("log");
  el.textContent += msg + "\n";
  el.scrollTop = el.scrollHeight;
};
const esc = (s) =>
  String(s).replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[c]));

const humanBytes = (n) => n < 1024 ? `${n} B` :
  n < 1024 * 1024 ? `${(n / 1024).toFixed(1)} KB` :
  `${(n / 1024 / 1024).toFixed(1)} MB`;

async function refresh() {
  const resp = await fetch("/api/files");
  const rid = resp.headers.get("X-Request-Id") || "?";
  const rows = await resp.json();
  log(`GET /api/files → ${resp.status} (${rows.length}) [rid=${rid}]`);
  const list = $("file-list");
  list.innerHTML = "";
  $("empty").hidden = rows.length > 0;
  for (const r of rows) {
    const li = document.createElement("li");
    li.innerHTML =
      `<span class="name"><a href="/files/${esc(r.id)}" target="_blank">${esc(r.filename)}</a></span>` +
      `<span class="bytes">${humanBytes(r.bytes)}</span>` +
      `<button class="secondary" data-id="${esc(r.id)}">×</button>`;
    list.appendChild(li);
  }
}

$("upload-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const f = $("file-input").files[0];
  if (!f) return;
  const fd = new FormData();
  fd.append("file", f);
  const resp = await fetch("/api/upload", { method: "POST", body: fd });
  const text = await resp.text();
  log(`POST /api/upload (${f.name}, ${humanBytes(f.size)}) → ${resp.status} ${text.slice(0, 80)}`);
  $("file-input").value = "";
  await refresh();
});

$("file-list").addEventListener("click", async (e) => {
  const btn = e.target.closest("button[data-id]");
  if (!btn) return;
  const resp = await fetch("/api/files/delete", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ id: btn.dataset.id }),
  });
  log(`POST /api/files/delete → ${resp.status}`);
  await refresh();
});

refresh();

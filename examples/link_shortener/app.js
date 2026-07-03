// Mere link shortener frontend — plain fetch, no framework.

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

async function refresh() {
  try {
    const resp = await fetch("/api/links");
    const rid = resp.headers.get("X-Request-Id") || "?";
    if (resp.status !== 200) {
      log(`GET /api/links → ${resp.status} [rid=${rid}]`);
      return;
    }
    const rows = await resp.json();
    log(`GET /api/links → ${resp.status} (${rows.length}) [rid=${rid}]`);
    render(rows);
  } catch (e) {
    log("fetch failed: " + e.message);
  }
}

function render(rows) {
  const tbody = $("links").querySelector("tbody");
  tbody.innerHTML = "";
  if (rows.length === 0) {
    $("links").hidden = true;
    $("empty").hidden = false;
    return;
  }
  $("links").hidden = false;
  $("empty").hidden = true;
  const base = location.origin;
  for (const r of rows) {
    const shortUrl = `${base}/${r.code}`;
    const tr = document.createElement("tr");
    tr.innerHTML =
      `<td class="code"><a href="/${escapeHtml(r.code)}" target="_blank">${escapeHtml(r.code)}</a></td>` +
      `<td class="url" title="${escapeHtml(r.url)}"><a href="${escapeHtml(r.url)}" target="_blank">${escapeHtml(r.url)}</a></td>` +
      `<td class="hits">${r.hits}</td>` +
      `<td><button class="danger" data-code="${escapeHtml(r.code)}">delete</button></td>`;
    tbody.appendChild(tr);
  }
}

$("btn-shorten").onclick = async () => {
  const url = $("new-url").value.trim();
  const code = $("new-code").value.trim();
  if (!url) return;
  const body = code ? { url, code } : { url };
  const resp = await fetch("/api/shorten", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const text = await resp.text();
  log(`POST /api/shorten → ${resp.status} ${text.slice(0, 100)}`);
  if (resp.status === 201) {
    $("new-url").value = "";
    $("new-code").value = "";
    await refresh();
  }
};

$("new-url").addEventListener("keydown", (e) => {
  if (e.key === "Enter") $("btn-shorten").click();
});
$("new-code").addEventListener("keydown", (e) => {
  if (e.key === "Enter") $("btn-shorten").click();
});

$("links").addEventListener("click", async (e) => {
  const btn = e.target.closest("button.danger");
  if (!btn) return;
  if (!confirm(`Delete /${btn.dataset.code}?`)) return;
  const resp = await fetch("/api/links/delete", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ code: btn.dataset.code }),
  });
  log(`POST /api/links/delete → ${resp.status}`);
  await refresh();
});

refresh();
setInterval(refresh, 5000);

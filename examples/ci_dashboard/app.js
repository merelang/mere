// Mere CI dashboard frontend — plain fetch, no framework.

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

// key format: `<repo>/<branch>/<workflow>` — split on the first two `/`
// only, so workflow names with `/` in them still work.
function splitKey(key) {
  const parts = key.split("/");
  if (parts.length < 3) return { repo: key, branch: "", workflow: "" };
  const repo = parts[0] + "/" + parts[1];
  const branch = parts[2];
  const workflow = parts.slice(3).join("/");
  return { repo, branch, workflow };
}

const KNOWN_BADGES = new Set([
  "success", "failure", "cancelled", "pending",
  "completed", "in_progress", "queued",
]);
const badgeClass = (v) => KNOWN_BADGES.has(v) ? v : "default";

async function refresh() {
  try {
    const resp = await fetch("/api/jobs");
    const rid = resp.headers.get("X-Request-Id") || "?";
    if (resp.status !== 200) {
      log(`GET /api/jobs → ${resp.status} [rid=${rid}]`);
      return;
    }
    const rows = await resp.json();
    log(`GET /api/jobs → ${resp.status} (${rows.length} rows) [rid=${rid}]`);
    render(rows);
  } catch (e) {
    log("fetch failed: " + e.message);
  }
}

function render(rows) {
  const tbody = $("jobs").querySelector("tbody");
  tbody.innerHTML = "";
  $("count").textContent = `${rows.length} tracked workflow${rows.length === 1 ? "" : "s"}`;
  if (rows.length === 0) {
    $("jobs").hidden = true;
    $("empty").hidden = false;
    return;
  }
  $("jobs").hidden = false;
  $("empty").hidden = true;
  for (const r of rows) {
    const { repo, branch, workflow } = splitKey(r.key);
    const tr = document.createElement("tr");
    const statusBadge = `<span class="badge ${badgeClass(r.status)}">${escapeHtml(r.status || "?")}</span>`;
    const conclusionBadge = r.conclusion
      ? `<span class="badge ${badgeClass(r.conclusion)}">${escapeHtml(r.conclusion)}</span>`
      : `<span class="badge default">—</span>`;
    const workflowCell = r.url
      ? `<a href="${escapeHtml(r.url)}" target="_blank">${escapeHtml(workflow)}</a>`
      : escapeHtml(workflow);
    tr.innerHTML =
      `<td><code>${escapeHtml(repo)}</code></td>` +
      `<td>${escapeHtml(branch)}</td>` +
      `<td>${workflowCell}</td>` +
      `<td>${statusBadge}</td>` +
      `<td>${conclusionBadge}</td>` +
      `<td>${escapeHtml(r.actor)}</td>` +
      `<td><small>${escapeHtml(r.updated_at)}</small></td>`;
    tbody.appendChild(tr);
  }
}

$("btn-refresh").onclick = refresh;
refresh();
setInterval(refresh, 5000);

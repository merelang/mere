// Mere feed reader frontend — plain fetch, no framework.

const $ = (id) => document.getElementById(id);
const log = (msg) => {
  const el = $("log");
  el.textContent += msg + "\n";
  el.scrollTop = el.scrollHeight;
};

async function call(method, path, body) {
  const opts = { method, credentials: "same-origin", headers: {} };
  if (body !== undefined) {
    opts.headers["Content-Type"] = "application/json";
    opts.body = JSON.stringify(body);
  }
  const resp = await fetch(path, opts);
  const rid = resp.headers.get("X-Request-Id") || "?";
  const text = await resp.text();
  log(`${method} ${path} → ${resp.status} [rid=${rid}] ${text.slice(0, 80)}`);
  return { status: resp.status, text };
}

const escapeHtml = (s) =>
  String(s).replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[c]));

async function refreshMe() {
  const me = await call("GET", "/api/me");
  if (me.status === 200) {
    $("who").textContent = "logged in as " + me.text.trim();
    $("login-box").hidden = true;
    $("logout-box").hidden = false;
    $("feeds").hidden = false;
    $("entries-section").hidden = false;
    await refreshFeeds();
    await refreshEntries();
  } else {
    $("who").textContent = "not logged in";
    $("login-box").hidden = false;
    $("logout-box").hidden = true;
    $("feeds").hidden = true;
    $("entries-section").hidden = true;
    $("feed-list").innerHTML = "";
    $("entry-list").innerHTML = "";
  }
}

async function refreshFeeds() {
  const resp = await call("GET", "/api/feeds");
  const list = $("feed-list");
  list.innerHTML = "";
  if (resp.status !== 200) return;
  let items;
  try { items = JSON.parse(resp.text); } catch { items = []; }
  if (items.length === 0) {
    list.innerHTML = "<li style='color:#888'>no subscriptions yet — paste a feed URL above</li>";
    return;
  }
  for (const f of items) {
    const li = document.createElement("li");
    li.innerHTML =
      `<span style="flex:1"><strong>${escapeHtml(f.title || f.url)}</strong>` +
      ` <span style="color:#888;font-size:0.85em">${escapeHtml(f.url)}</span></span>` +
      `<button class="secondary" data-act=del data-url="${escapeHtml(f.url)}">unsubscribe</button>`;
    list.appendChild(li);
  }
}

async function refreshEntries() {
  const resp = await call("GET", "/api/entries");
  const list = $("entry-list");
  list.innerHTML = "";
  if (resp.status !== 200) return;
  let items;
  try { items = JSON.parse(resp.text); } catch { items = []; }
  if (items.length === 0) {
    list.innerHTML = "<li style='color:#888;border-left:none;background:transparent'>no cached entries — hit \"refresh all\" after subscribing</li>";
    return;
  }
  for (const e of items) {
    const li = document.createElement("li");
    li.innerHTML =
      `<div class="entry-title"><a href="${escapeHtml(e.link)}" target="_blank">${escapeHtml(e.title)}</a></div>` +
      `<div class="entry-meta">${escapeHtml(e.date)}</div>` +
      `<div class="entry-summary">${escapeHtml(e.summary).slice(0, 400)}</div>`;
    list.appendChild(li);
  }
}

$("btn-signup").onclick = async () => {
  await call("POST", "/api/signup", { user: $("user").value, pass: $("pass").value });
  await refreshMe();
};
$("btn-login").onclick = async () => {
  await call("POST", "/api/login", { user: $("user").value, pass: $("pass").value });
  await refreshMe();
};
$("btn-logout").onclick = async () => {
  await call("POST", "/api/logout");
  await refreshMe();
};
$("btn-subscribe").onclick = async () => {
  const url = $("new-url").value.trim();
  if (!url) return;
  await call("POST", "/api/feeds", { url });
  $("new-url").value = "";
  await refreshFeeds();
};
$("btn-refresh").onclick = async () => {
  log("(refreshing — this spawns curl for each feed and may take a few seconds)");
  await call("POST", "/api/feeds/refresh");
  await refreshFeeds();
  await refreshEntries();
};
$("new-url").addEventListener("keydown", (e) => {
  if (e.key === "Enter") $("btn-subscribe").click();
});
$("feed-list").addEventListener("click", async (e) => {
  const btn = e.target.closest("button");
  if (!btn) return;
  if (btn.dataset.act === "del") {
    await call("POST", "/api/feeds/delete", { url: btn.dataset.url });
    await refreshFeeds();
    await refreshEntries();
  }
});

refreshMe();

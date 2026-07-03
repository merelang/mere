// Mere JWT demo frontend — token kept in localStorage, sent as
// `Authorization: Bearer <token>` on every /api/* call. No cookies.

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

const TOKEN_KEY = "mere_jwt";
const getToken = () => localStorage.getItem(TOKEN_KEY) || "";
const setToken = (t) => localStorage.setItem(TOKEN_KEY, t);
const clearToken = () => localStorage.removeItem(TOKEN_KEY);

async function call(method, path, body) {
  const opts = { method, headers: {} };
  const t = getToken();
  if (t) opts.headers["Authorization"] = "Bearer " + t;
  if (body !== undefined) {
    opts.headers["Content-Type"] = "application/json";
    opts.body = JSON.stringify(body);
  }
  const resp = await fetch(path, opts);
  const rid = resp.headers.get("X-Request-Id") || "?";
  const text = resp.status === 204 ? "" : await resp.text();
  log(`${method} ${path} → ${resp.status} [rid=${rid}] ${text.slice(0, 80)}`);
  return { status: resp.status, text };
}

async function refresh() {
  const t = getToken();
  if (!t) {
    $("token-box").hidden = true;
    $("tasks-box").hidden = true;
    return;
  }
  const me = await call("GET", "/api/me");
  if (me.status !== 200) {
    log("stored token invalid — clearing");
    clearToken();
    $("token-box").hidden = true;
    $("tasks-box").hidden = true;
    return;
  }
  const who = JSON.parse(me.text).user;
  $("who").textContent = who;
  $("token-raw").textContent = t;
  $("token-box").hidden = false;
  $("tasks-box").hidden = false;
  await refreshTasks();
}

async function refreshTasks() {
  const resp = await call("GET", "/api/tasks");
  const list = $("task-list");
  list.innerHTML = "";
  if (resp.status !== 200) return;
  const rows = JSON.parse(resp.text);
  if (rows.length === 0) {
    list.innerHTML = '<li style="color:#94a3b8">no tasks yet</li>';
    return;
  }
  for (const r of rows) {
    const li = document.createElement("li");
    li.innerHTML =
      `<span class="text">${esc(r.text)}</span>` +
      `<span class="id">${esc(r.id.slice(0, 8))}</span>` +
      `<button class="secondary" data-id="${esc(r.id)}">×</button>`;
    list.appendChild(li);
  }
}

$("btn-register").onclick = async () => {
  await call("POST", "/api/register",
    { user: $("user").value, pass: $("pass").value });
};

$("btn-login").onclick = async () => {
  const resp = await call("POST", "/api/login",
    { user: $("user").value, pass: $("pass").value });
  if (resp.status === 200) {
    const { token } = JSON.parse(resp.text);
    setToken(token);
    await refresh();
  }
};

$("btn-logout").onclick = () => { clearToken(); refresh(); };

$("task-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const text = $("task-text").value.trim();
  if (!text) return;
  const resp = await call("POST", "/api/tasks", { text });
  if (resp.status === 201) {
    $("task-text").value = "";
    await refreshTasks();
  }
});

$("task-list").addEventListener("click", async (e) => {
  const btn = e.target.closest("button[data-id]");
  if (!btn) return;
  await call("POST", "/api/tasks/delete", { id: btn.dataset.id });
  await refreshTasks();
});

refresh();

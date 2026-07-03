// Mere todo app frontend — plain fetch, no framework.
// Talks to /api/* endpoints served by http_todo_app.mere.

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
  return { status: resp.status, text, rid };
}

async function refreshMe() {
  const me = await call("GET", "/api/me");
  if (me.status === 200) {
    $("who").textContent = "logged in as " + me.text.trim();
    $("login-box").hidden = true;
    $("logout-box").hidden = false;
    $("todos").hidden = false;
    await refreshTodos();
  } else {
    $("who").textContent = "not logged in";
    $("login-box").hidden = false;
    $("logout-box").hidden = true;
    $("todos").hidden = true;
    $("todo-list").innerHTML = "";
  }
}

async function refreshTodos() {
  const resp = await call("GET", "/api/todos");
  const list = $("todo-list");
  list.innerHTML = "";
  if (resp.status !== 200) return;
  // Response is a JSON array of {id, text, done} objects.
  let items;
  try { items = JSON.parse(resp.text); } catch (e) { items = []; }
  for (const it of items) {
    const li = document.createElement("li");
    if (it.done) li.classList.add("done");
    li.innerHTML =
      `<button data-act=toggle data-id="${it.id}">${it.done ? "↺" : "✓"}</button>` +
      `<span>${it.text}</span>` +
      `<button data-act=del data-id="${it.id}" style="margin-left:auto">✕</button>`;
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
$("btn-add").onclick = async () => {
  const text = $("new-text").value.trim();
  if (!text) return;
  await call("POST", "/api/todos", { text });
  $("new-text").value = "";
  await refreshTodos();
};
$("new-text").addEventListener("keydown", (e) => {
  if (e.key === "Enter") $("btn-add").click();
});
$("todo-list").addEventListener("click", async (e) => {
  const btn = e.target.closest("button");
  if (!btn) return;
  const id = btn.dataset.id;
  const act = btn.dataset.act;
  if (act === "toggle") await call("POST", "/api/todos/toggle", { id });
  if (act === "del") await call("POST", "/api/todos/delete", { id });
  await refreshTodos();
});

refreshMe();

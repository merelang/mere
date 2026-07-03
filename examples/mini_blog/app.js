// Mere mini blog admin console. The public post list is server-
// rendered into <!--POSTS--> in index.html; this script only handles
// the admin login + write flow.

const $ = (id) => document.getElementById(id);
const log = (msg) => {
  const el = $("log");
  el.textContent += msg + "\n";
  el.scrollTop = el.scrollHeight;
};

let isAdmin = false;

async function whoami() {
  const resp = await fetch("/api/posts", { credentials: "same-origin" });
  // No dedicated /api/me — infer admin from ability to write. Just
  // toggle UI based on whether the login cookie is set.
  // Simpler: probe with a HEAD-ish POST that we know will 401 for
  // anonymous. We can just watch for the cookie in document.cookie.
  isAdmin = /(?:^|;\s*)session=admin-/.test(document.cookie);
  updateUI();
  log(`GET /api/posts → ${resp.status} (admin=${isAdmin})`);
}

function updateUI() {
  $("admin").hidden = !isAdmin;
  $("login-box").hidden = isAdmin;
}

$("btn-login").onclick = async () => {
  const resp = await fetch("/api/login", {
    method: "POST",
    credentials: "same-origin",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ password: $("admin-pass").value }),
  });
  const text = await resp.text();
  log(`POST /api/login → ${resp.status} ${text.trim()}`);
  isAdmin = resp.status === 200;
  updateUI();
};

$("btn-logout").onclick = async () => {
  await fetch("/api/logout", { method: "POST", credentials: "same-origin" });
  isAdmin = false;
  updateUI();
  log("logged out");
};

$("btn-save").onclick = async () => {
  const slug = $("new-slug").value.trim();
  const title = $("new-title").value.trim();
  const body = $("new-body").value;
  if (!slug || !title) { log("slug and title required"); return; }
  const resp = await fetch("/api/posts", {
    method: "POST",
    credentials: "same-origin",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ slug, title, body }),
  });
  const text = await resp.text();
  log(`POST /api/posts → ${resp.status} ${text.slice(0, 80)}`);
  if (resp.status === 201) {
    location.reload();
  }
};

whoami();

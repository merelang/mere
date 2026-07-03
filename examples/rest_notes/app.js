// Mere REST notes frontend. Keeps the ETag from the last GET/PUT/
// PATCH response for the currently-open note, sends it as If-Match
// on the next mutation. If the server rejects with 412, the user
// gets a clear "someone else edited this — refresh" prompt.

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

let currentId = null;
let currentEtag = null;

async function refreshList() {
  const resp = await fetch("/api/notes");
  const rid = resp.headers.get("X-Request-Id") || "?";
  const rows = await resp.json();
  log(`GET /api/notes → ${resp.status} (${rows.length}) [rid=${rid}]`);
  const list = $("note-list");
  list.innerHTML = "";
  for (const r of rows) {
    const li = document.createElement("li");
    li.innerHTML =
      `<span class="title" data-id="${esc(r.id)}">${esc(r.title)}</span>` +
      `<span class="version">v${r.version}</span>`;
    list.appendChild(li);
  }
}

async function openNote(id) {
  const resp = await fetch("/api/notes/" + encodeURIComponent(id));
  if (resp.status !== 200) { log("open failed: " + resp.status); return; }
  const note = await resp.json();
  const etag = resp.headers.get("ETag");
  log(`GET /api/notes/${id} → 200 ETag=${etag}`);
  currentId = id;
  currentEtag = etag;
  $("edit-box").hidden = false;
  $("edit-id").textContent = id.slice(0, 8);
  $("edit-etag").textContent = etag || "";
  $("edit-title").value = note.title;
  $("edit-body").value = note.body;
}

async function saveNote(method) {
  if (!currentId || !currentEtag) return;
  const title = $("edit-title").value;
  const body = $("edit-body").value;
  const resp = await fetch("/api/notes/" + encodeURIComponent(currentId), {
    method,
    headers: {
      "Content-Type": "application/json",
      "If-Match": currentEtag,
    },
    body: JSON.stringify({ title, body }),
  });
  const rid = resp.headers.get("X-Request-Id") || "?";
  log(`${method} /api/notes/${currentId} If-Match=${currentEtag} → ${resp.status} [rid=${rid}]`);
  if (resp.status === 412) {
    const serverEtag = resp.headers.get("ETag");
    alert(`412 Precondition Failed — someone else edited this note (server is at ${serverEtag}). Refresh to see the latest.`);
    return;
  }
  if (resp.status === 200) {
    const note = await resp.json();
    const newEtag = resp.headers.get("ETag");
    currentEtag = newEtag;
    $("edit-etag").textContent = newEtag;
    $("edit-title").value = note.title;
    $("edit-body").value = note.body;
    await refreshList();
  }
}

$("new-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const title = $("new-title").value.trim();
  const body = $("new-body").value;
  if (!title) return;
  const resp = await fetch("/api/notes", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ title, body }),
  });
  const etag = resp.headers.get("ETag");
  const loc = resp.headers.get("Location");
  log(`POST /api/notes → ${resp.status} ETag=${etag} Location=${loc}`);
  if (resp.status === 201) {
    $("new-title").value = "";
    $("new-body").value = "";
    await refreshList();
  }
});

$("note-list").addEventListener("click", (e) => {
  const el = e.target.closest(".title");
  if (el) openNote(el.dataset.id);
});

$("edit-form").addEventListener("submit", (e) => { e.preventDefault(); saveNote("PUT"); });
$("btn-patch").addEventListener("click", () => saveNote("PATCH"));
$("btn-delete").addEventListener("click", async () => {
  if (!currentId) return;
  if (!confirm("Delete this note?")) return;
  const resp = await fetch("/api/notes/" + encodeURIComponent(currentId), {
    method: "DELETE",
    headers: { "If-Match": currentEtag },
  });
  log(`DELETE /api/notes/${currentId} → ${resp.status}`);
  if (resp.status === 204) {
    $("edit-box").hidden = true;
    currentId = null;
    currentEtag = null;
    await refreshList();
  }
});
$("btn-close").addEventListener("click", () => {
  $("edit-box").hidden = true;
  currentId = null;
  currentEtag = null;
});

refreshList();

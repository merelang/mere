// Mere CSV export frontend. Download triggers a plain <a> click
// so the browser handles the streamed response natively. Preview
// uses fetch + ReadableStream so we can show partial progress.

const $ = (id) => document.getElementById(id);
const log = (msg) => {
  const el = $("log");
  el.textContent += msg + "\n";
  el.scrollTop = el.scrollHeight;
};

$("btn-download").addEventListener("click", () => {
  const n = Number($("rows").value) || 1000;
  const url = `/api/logs.csv?rows=${n}`;
  log(`GET ${url} — browser handles download`);
  const a = document.createElement("a");
  a.href = url;
  a.download = `logs-${n}.csv`;
  document.body.appendChild(a);
  a.click();
  a.remove();
});

$("btn-preview").addEventListener("click", async () => {
  const n = Number($("rows").value) || 1000;
  const url = `/api/logs.csv?rows=${n}`;
  const t0 = performance.now();
  const resp = await fetch(url);
  const rid = resp.headers.get("X-Request-Id") || "?";
  log(`GET ${url} → ${resp.status} rid=${rid}`);
  const reader = resp.body.getReader();
  const dec = new TextDecoder();
  let buf = "";
  let lines = 0;
  const preview = $("preview");
  preview.textContent = "";
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += dec.decode(value, { stream: true });
    const parts = buf.split("\n");
    buf = parts.pop();
    for (const line of parts) {
      lines++;
      if (lines <= 20) preview.textContent += line + "\n";
      else if (lines === 21) preview.textContent += "... (truncated, full stream continues) ...\n";
    }
  }
  const t1 = performance.now();
  log(`streamed ${lines} lines in ${(t1 - t0).toFixed(0)}ms`);
});

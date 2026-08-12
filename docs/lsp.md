# The language server

```sh
mere lsp
```

Speaks LSP over stdin and stdout. What it does today is **diagnostics** — every
syntax error in the buffer, republished on each keystroke, and the first type
error once the file parses — and **hover**, which reports the type inference gave
whatever is under the cursor.

It is the same check the compiler runs — `Pipeline.check`, which the CLI also
goes through. A language server that agrees with the compiler on good days
is worse than none, because it teaches you to distrust the underline.

## Editors

**Neovim** (built-in client, no plugin):

```lua
vim.api.nvim_create_autocmd("FileType", {
  pattern = "mere",
  callback = function(args)
    vim.lsp.start({
      name = "mere",
      cmd = { "mere", "lsp" },
      root_dir = vim.fs.dirname(vim.fs.find({ "mere.toml", ".git" }, { upward = true })[1]),
    })
  end,
})
vim.filetype.add({ extension = { mere = "mere" } })
```

**VS Code** needs an extension to launch it; the server side of that extension is
`{ command: "mere", args: ["lsp"] }` with `documentSelector: [{ language: "mere" }]`.

**Anything else**: the command is `mere lsp`, there are no arguments and no
configuration. It reads `Content-Length`-framed JSON-RPC on stdin and writes the
same on stdout, so a client that can start a process can talk to it.

## What it answers

| method | behaviour |
|---|---|
| `initialize` | capabilities: full-text sync (`textDocumentSync: 1`), `hoverProvider` |
| `textDocument/hover` | the inferred type of the narrowest node under the cursor, as `name : type` when it is a name |
| `textDocument/didOpen` / `didChange` / `didSave` | check the buffer, publish diagnostics |
| `textDocument/didClose` | publish an empty list, clearing the underlines |
| `shutdown` / `exit` | as specified |
| anything else with an id | `-32601 method not found`, rather than silence |

Diagnostics carry a range with a **width**, so the underline covers the token
rather than one character of it, and positions are converted from Mere's 1-based
lines and columns to the protocol's 0-based ones.

The buffer is what gets checked, not the file on disk — an editor owns a file
while it is open. But `import` still resolves against the **file's** directory,
taken from the document URI, so imports work in an unsaved buffer.

## Hover, and what a position means here

A `Loc.t` in this compiler is a line, a column and a **width** — the token a node
was built from, not a span over its subtree. So "the node at this position" means
the narrowest node whose own token contains the cursor, which is what makes
hovering inside a call answer about the piece under the cursor rather than about
the whole application.

The type comes from the typer having written it onto the node (`e.ty <- Some t`)
during the check that produced the diagnostics. There is no second inference pass
and no separate index: the hover is reading what the compiler already concluded.

The server keeps **the last tree that type-checked**. While a line is half typed
the file does not check, and an answer from a moment ago beats no answer at all —
so hover keeps working through an edit, and catches up when the file is valid
again.

## What it does not answer yet

- **Completion and go-to-definition.** Both ask the same question hover does
  (`Query.node_at`), plus a notion of scope: what is bound here, and where. That
  is the next slice.
- **More than one type error.** Syntax errors are all reported, because the
  parser recovers at declaration boundaries (v0.1.203). The type-checker still
  raises on the first problem, so a file that parses gets one type error at a
  time. Making the typer collect instead of raise is its own slice, and a larger
  one — every `raise` in it is a place that currently gets to assume the rest of
  the pass will not run.
- **Positions inside imported files.** An error in an imported file is reported
  with the position it has *there*, against the importing file's URI, which is
  wrong. Diagnostics need to carry the file they came from before this can be
  fixed properly.
- **Incremental sync.** The whole buffer arrives on every change. The check
  re-reads all of it anyway, so incremental sync would buy nothing yet and cost
  a class of desynchronisation bugs.
- **Warnings.** The compiler's warnings (a top-level name that collides with a C
  keyword, say) are printed to stderr by the pipeline rather than returned as
  data, so they do not become diagnostics. Only errors are underlined.

## Testing it

`sh scripts/lsp_smoke.sh` drives the real process through its wire format: a
canned session that opens a file with three syntax errors, edits it into one with
a type error, then into a clean one, and checks the framing and the three
`publishDiagnostics` that come back.

The handler itself is a function — message and state in, messages out — so the
suite tests it directly, without a process. That split is deliberate: the only
untested part is the three lines of IO in `Lsp.serve`.

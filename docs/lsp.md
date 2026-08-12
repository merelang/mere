# The language server

```sh
mere lsp
```

Speaks LSP over stdin and stdout. What it does today is **diagnostics** — every
syntax error in the buffer, republished on each keystroke, and the first type
error once the file parses — **hover**, which reports the type inference gave
whatever is under the cursor, **go to definition**, and **completion**.

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
| `initialize` | capabilities: full-text sync (`textDocumentSync: 1`), `hoverProvider`, `definitionProvider`, `completionProvider` |
| `textDocument/hover` | the inferred type of the narrowest node under the cursor, as `name : type` when it is a name |
| `textDocument/definition` | where the name under the cursor was bound, when that is somewhere in this file |
| `textDocument/completion` | every name visible at the cursor, innermost first, with its type |
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

**Warnings are diagnostics too** (severity 2): a non-exhaustive `match`, a
top-level name that collides with a C keyword. They used to be printed to stderr
from inside the compiler, which is fine for a terminal and useless to anything
else — an editor cannot underline a line written to a stream it is not reading.
The pipeline hands them over as data now and the CLI does its own printing.

**A syntax error inside an `import`** is published against **that file's** URI,
where its line numbers mean something, rather than against the buffer. The server
remembers which other files it has spoken about and clears them when the import is
fixed — a diagnostic stays on screen until the server says otherwise, and "never
mind" is exactly the message nobody thinks to send.

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

## Go to definition, and scope

Scope is recomputed by walking down to the position, not kept in an index. The
walk descends one path rather than the whole tree, it cannot go stale, and it has
no invalidation to get wrong — the same reason hover reads the typer's
annotations instead of building a table beside them.

A binder is in scope for the parts of itself where it is really visible: a `let`
binds its body but not its own value expression, a `fn` binds its body, a
`let rec` binds both, a match arm's pattern binds that arm. Getting that wrong is
how a server sends you to the wrong `x`, so each case is a test.

Two things it deliberately declines to answer:

- **A prelude name** (`print_int`, `str_len`) is genuinely in scope, but its
  position is a line in the prelude's *own* text. Jumping there would send the
  editor to an arbitrary line of the user's file, so it answers nothing at all.
  The count of prelude declarations is recorded when the program is parsed, which
  is what makes them distinguishable.
- **A parameter** points at the `fn` that introduced it rather than at the
  parameter name, because `Fun` carries the name but not the name's own position.

## Completion

Every name visible at the position, innermost first, one entry per name — an
inner binding shadows an outer one, and offering both would offer a name that
cannot be reached. Each carries its inferred type as the `detail` line, and a
kind so the editor draws a function icon for a function.

Prelude names are offered (`str_len` is exactly what you want in the list) but
`sortText` puts them after the file's own names, and the prelude's internal
helpers — the ones it names with a leading underscore — are left out.

There are no trigger characters: this language has no `.` member access to
complete after, so the list arrives when the editor asks for it. The response is
marked complete, so an editor filters it as you keep typing rather than asking
again.

## What it does not answer yet

- **More than one type error.** Syntax errors are all reported, because the
  parser recovers at declaration boundaries (v0.1.203). The type-checker still
  raises on the first problem, so a file that parses gets one type error at a
  time. Making the typer collect instead of raise is its own slice, and a larger
  one — every `raise` in it is a place that currently gets to assume the rest of
  the pass will not run.

- **Incremental sync.** The whole buffer arrives on every change. The check
  re-reads all of it anyway, so incremental sync would buy nothing yet and cost
  a class of desynchronisation bugs.
- **Type errors inside imported files** are still reported against the importing
  file. Syntax errors carry the file they came from and are published against it;
  type errors do not, because by then the imported declarations have been merged
  into one program and nothing records where each came from.

## Testing it

`sh scripts/lsp_smoke.sh` drives the real process through its wire format: a
canned session that opens a file with three syntax errors, edits it into one with
a type error, then into a clean one, and checks the framing and the three
`publishDiagnostics` that come back.

The handler itself is a function — message and state in, messages out — so the
suite tests it directly, without a process. That split is deliberate: the only
untested part is the three lines of IO in `Lsp.serve`.

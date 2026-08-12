# The language server

```sh
mere lsp
```

Speaks LSP over stdin and stdout. What it does today is **diagnostics** — every
syntax error in the buffer, republished on each keystroke, and the first type
error once the file parses — **hover**, which reports the type inference gave
whatever is under the cursor, **go to definition**, **completion**, an
**outline**, **formatting**, **semantic highlighting**, **find references** and
**rename**.

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

**VS Code**: install the [Mere extension](https://github.com/merelang/mere-vscode),
which starts this server and speaks to it. It finds `mere` on PATH; `mere.path`
points it at a local build.

**Anything else**: the command is `mere lsp`, there are no arguments and no
configuration. It reads `Content-Length`-framed JSON-RPC on stdin and writes the
same on stdout, so a client that can start a process can talk to it.

## What it answers

| method | behaviour |
|---|---|
| `initialize` | capabilities: full-text sync (`textDocumentSync: 1`), `hoverProvider`, `definitionProvider`, `completionProvider`, `documentSymbolProvider`, `documentFormattingProvider`, `semanticTokensProvider` |
| `textDocument/hover` | the inferred type of the narrowest node under the cursor, as `name : type` when it is a name |
| `textDocument/definition` | where the name under the cursor was bound, when that is somewhere in this file |
| `textDocument/completion` | every name visible at the cursor, innermost first, with its type |
| `textDocument/documentSymbol` | the file's top-level declarations, for the outline and symbol search |
| `textDocument/formatting` | the whole document, formatted — the same function `mere fmt` runs |
| `textDocument/semanticTokens/full` | which names are parameters, functions, constructors |
| `textDocument/references` | every occurrence of the binding under the cursor |
| `textDocument/rename` / `prepareRename` | the same occurrences, rewritten; refuses what this file does not own |
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

**An error inside an `import`** — of any kind — is published against **that
file's** URI,
where its line numbers mean something, rather than against the buffer. A position
carries the file it came from (the lexer stamps every token from an imported
file), so this works for a type error raised long after the parse, not just for a
syntax error. The server remembers which other files it has spoken about and
clears them when the import is fixed — a diagnostic stays on screen until the
server says otherwise, and "never mind" is exactly the message nobody thinks to
send.

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

## Formatting, the outline, and colour

**Formatting** is `mere fmt`'s own function, so format-on-save and the command
line cannot come to different conclusions about what formatted means. Two
refusals worth knowing: a file that does not parse is left alone (replacing a
buffer with the best guess of a parser that failed is how somebody loses work),
and an already-formatted file produces *no edit at all* rather than an edit that
changes nothing.

**The outline** lists the file's value declarations, telling a function from a
value by its type. A `type` declaration is missing from it, and honestly so:
`Top_type` carries a name and its variants and no position at all, so it cannot
be pointed at without guessing which line it is on.

**Semantic tokens** are the compiler saying which names are parameters, which are
functions, which are constructors — the distinctions a regular expression cannot
make, and the reason an editor's grammar is only half the story. The grammar
still handles keywords, strings and numbers, which it is perfectly good at. A
constructor in a *pattern* is not tokenised: patterns are not expressions, and
the walk that produces these follows expressions.

## References and rename

The same question, and the difficulty in both is **shadowing**: two `x`es in one
file may be two different things, and treating them as one is a rename that
breaks the program. So the walk resolves every occurrence to the binding it
actually refers to, and the answer is the occurrences that resolved to the same
one.

```mere
let x = 1;                        // renaming this one touches
let f = fn (n: int) ->
  let x = n + 1 in                // ... not this one, nor
  x + x;                          // ... these
let _ = print_int (f x + x);      // ... but these two
```

Binder positions are included, so the cursor may be on the definition rather than
on a use.

**Rename refuses what this file does not own.** A prelude name or a builtin has
its definition somewhere the edit cannot reach, and renaming the uses while
leaving the definition is worse than refusing. The refusal comes back from
`prepareRename`, which is where an editor asks before offering a box to type in.

## What it does not answer yet

- **The rarer type errors still stop a declaration.** A mismatch and an unknown
  name are collected — those are nearly all of them — and inference carries on
  with a fresh variable. The other twenty or so `raise` sites in the typer still
  end that declaration's check, and the recovery at the declaration boundary
  picks up from there. So the worst case is one error for a declaration rather
  than all of them, never one error for the file.

- **Incremental sync.** The whole buffer arrives on every change. The check
  re-reads all of it anyway, so incremental sync would buy nothing yet and cost
  a class of desynchronisation bugs.


## What it costs per keystroke

Re-checking the whole document on every change is only reasonable if checking is
cheap, and this is the first thing that ever made the compiler's own cost
visible — a batch compiler that takes two seconds is fine, an editor that takes
two seconds per character is not.

Measured end to end, driving the server the way an editor does (didChange, then
wait for `publishDiagnostics`):

| document | per keystroke |
|---|---|
| 4 000 lines | 32ms |
| 8 000 lines | 65ms |
| 16 000 lines | 135ms |
| 22 466 lines (mere-ruby's `main.mere`) | 1251ms |

Those numbers are from v0.1.220. Before it they were 524ms, 1834ms, 7741ms and
5261ms: `generalize` scanned the whole type environment per binding, so checking
was quadratic in the number of bindings. `scripts/infer_scaling.sh` is the guard
that keeps it linear.

The largest file is still over a second, and the remaining cost is spread evenly
across parsing, inference and the move checker rather than concentrated in one
place. Getting below it means not re-checking everything — which is what
incremental sync above is really for, and neither is worth doing on a guess about
which documents people actually edit.


## Testing it

`sh scripts/lsp_smoke.sh` drives the real process through its wire format: a
canned session that opens a file with three syntax errors, edits it into one with
a type error, then into a clean one, and checks the framing and the three
`publishDiagnostics` that come back.

The handler itself is a function — message and state in, messages out — so the
suite tests it directly, without a process. That split is deliberate: the only
untested part is the three lines of IO in `Lsp.serve`.

`sh scripts/infer_scaling.sh` guards the latency above, by measuring rather than
asserting: two files eight times apart, failing if the larger takes more than 20x
the smaller. Linear predicts 8x and quadratic predicts 64x, so the bound survives
a busy machine and still fails the moment an environment scan comes back.

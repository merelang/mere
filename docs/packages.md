# Packages (v0.1)

Mere's package system is intentionally small. A project is a directory
that contains a `.mere_modules/` subdirectory; every top-level entry in
that subdir is a "package", every `.mere` file inside a package is a
"module". Imports of the form `import "<package>/<module>.mere";`
resolve by walking up from the importing file toward the filesystem
root until a `.mere_modules/` directory is found, then looking up
`<package>/<module>.mere` inside it.

## Layout

    my_app/
      main.mere                                  ← your code
      .mere_modules/
        mere-http/
          router.mere                            ← a package's module
          session.mere
        mere-db/
          pg.mere
      README.md

Inside `main.mere`:

    import "mere-http/router.mere";
    import "mere-db/pg.mere";

The resolver walks from `my_app/main.mere` up to `my_app/`, finds
`.mere_modules/`, and reads `.mere_modules/mere-http/router.mere` and
`.mere_modules/mere-db/pg.mere`.

## Nested imports

When a vendored module imports another vendored module, the resolver
walks up from *that* module's directory. Since it's still inside your
project tree, it finds the same top-level `.mere_modules/`.

    my_app/main.mere
      → imports "mere-http/router.mere"
        → walks up from .mere_modules/mere-http/ to my_app/
        → finds .mere_modules/, resolves nested imports there
        → imports "mere-cookie/cookie.mere"
          → resolves to .mere_modules/mere-cookie/cookie.mere

This mirrors Node.js's `node_modules` walk semantics. Cross-package
imports Just Work as long as everything lives under one project root.

## How to vendor a package

Manual vendoring always works — the compiler only cares about the on-disk
layout, not how the files got there — and `mere install` (below) automates
it from a manifest. There is no central registry. Suitable manual methods:

**git clone** (recommended for tracked deps):

    cd my_app
    mkdir -p .mere_modules
    git clone https://github.com/<owner>/<pkg-name> .mere_modules/<pkg-name>

**git submodule** (recommended when the app itself is a git repo):

    cd my_app
    git submodule add https://github.com/<owner>/<pkg-name> \
        .mere_modules/<pkg-name>

**tarball drop** (for one-shot bundling):

    curl -L https://example.com/<pkg>.tar.gz | tar xz -C .mere_modules/

All three produce the same on-disk layout. The compiler doesn't care
how the files got there.

## Precedence

Import resolution tries paths in this order:

1. `<current_file_dir>/<path>` — historical behaviour for
   same-directory / relative imports (`import "./util.mere"` still
   works exactly as before).
2. `<nearest_.mere_modules_up>/path` — the new v0.1 rule.
3. Each directory in `-I` (CLI) plus `MERE_PATH` (env var), in that
   order.

Absolute paths (starting with `/`) skip all of the above and resolve
literally.

## Global module dirs

For a shared cache across projects — e.g. `~/mere-modules/` — use
`MERE_PATH`. It's colon-separated (`:` on POSIX). Set it in your
shell rc:

    export MERE_PATH=~/mere-modules

Then `import "hello/greet.mere";` in *any* project also picks up
`~/mere-modules/hello/greet.mere` as a fallback after the project-
local `.mere_modules/` is exhausted.

## v0.2 (experimental): `mere.toml` + `mere install`

Manual vendoring works, but `mere install` automates it from a manifest.
Write a `mere.toml` next to your entry file:

    [package]
    name = "my_app"
    version = "0.1.0"

    [dependencies]
    http = { git = "https://github.com/merelang/mere", subdir = "contrib/http", rev = "<commit>" }
    db   = { git = "https://github.com/merelang/mere", subdir = "contrib/db",   rev = "<commit>" }

then:

    mere install            # or: mere install <dir>

This fetches each dependency at its pinned `rev` (a monorepo `subdir` is
supported, so you can depend on one package inside a larger repo) and
writes it under its **module path**. Each fetched package's own `mere.toml`
`[package] path` decides where it lands — `.mere_modules/github.com/owner/repo/`
— so a Go-style full-path import (`import "github.com/owner/repo/x.mere"`)
resolves directly. A package with no declared path falls back to its bare
source-directory name (legacy contrib layout), and `../` relative imports
inside a monorepo are still followed.

**Transitive dependencies across repos** are pulled in automatically: the
installer reads each fetched package's own `[dependencies]` and follows them,
so an app that depends on `A` (which depends on `B` in another repo) gets `B`
too, even though the app never names it.

A `mere.lock` records every resolved package (including transitive) with its
full commit sha and a content hash. On a later install, that hash is
**verified**: if a pinned `(git, rev)` coordinate ever produces different
content — a moved tag, a force-push, a corrupt cache — the install fails
loudly (go.sum-style integrity), rather than silently building against
something else.

Still minimal: `rev` is an exact git commit (no version ranges), there's
no central registry, and installs are whole-package.

### Running without a compiler checkout: `[host]` + `mere serve`

A compiled `.wasm` needs a Node host to supply its extern imports
(`puts`, `read_file`, `http_serve`, `redis_*`, `sse_*`, …). Those live in
the compiler repo, so an app couldn't run without a checkout. Add a
`[host]` section to fetch them into a self-contained `.mere_host/`:

    [host]
    git = "https://github.com/merelang/mere"
    rev = "<commit>"

`mere install` then vendors `scripts/*.js` + `contrib/**/*.glue.js` into
`.mere_host/`, flattening every `require("…/x.js")` to `require("./x.js")`
so the bundle stands alone. Run a compiled server with:

    mere serve app.wasm      # = node .mere_host/run_http_server.js app.wasm

So a released `mere` binary + `mere install` is enough to build *and* run
an app — no compiler source tree required at runtime.

## The compiler a package needs

```toml
[package]
name = "thing"
version = "0.1.0"
mere = ">= 0.1.480"     # optional; `x.y.z` means the same as `>= x.y.z`
```

Checked against the compiler that is running — by `mere install`, for this
package and for every dependency it fetches, and by every build of a file
inside the package. Without it the failure still happens, just later and
mute: the newer syntax reaches an older parser and comes back as a **syntax
error in somebody else's file**.

A manifest with no `mere` line makes no claim and is never refused. A line the
compiler cannot read (`^1.2`, a range) is refused by name rather than ignored:
a constraint nobody reads is worse than no constraint, because it looks like
one.

### `mere fix` — make the declared floor true

```sh
mere fix app.mere
# fix: ./mere.toml -- set `mere = ">= 0.1.422"`
#       (128-bit SIMD lane types (`f64x2` / `u8x16`) needs it)
```

Parses the file, asks which of the compiler's dated features it actually uses,
and writes the highest into the nearest `mere.toml`. **It writes that line and
nothing else** — a tool that "fixes" a file is one people stop reading the diff
of.

`mere --features` prints the table it computes from (name, version, and the
word `scripts/version_floor_check.sh` re-derives the version from in
`docs/changelog.md`, so a row invented by hand fails the gate). The table is
short on purpose: a row earns its place only for a feature that old compilers
in the wild do not have.

## The API surface, as data

```sh
mere --decls --json app.mere
```

```json
{
  "mere": "0.1.504",
  "requires": ">= 0.1.422",
  "values": [ { "name": "pick", "type": "(color -> int)", "status": "ok", "note": "" } ],
  "types":  [ { "name": "color", "kind": "variant", "params": [], "line": 1,
                "constructors": [ { "name": "Red", "payload": null } ] } ]
}
```

The same surface `mere --decls` prints, plus the type declarations and the
package's declared floor — the promise and the surface in one document, which
is how Gleam's `package-interface` carries its version constraint too.

**What it is for**: the diff between two versions of a package. `mere fix`
writes a floor from the features a file uses; it cannot say whether the API a
downstream repository depends on has changed. That question is a diff of this.

`status` is `ok`, `duplicate` or `shadows-builtin`: the last two are the
declarations `--decls` prints commented out, because pasting them back would
change the program. `scripts/decls_json_check.sh` rebuilds the text from this
JSON and compares it byte for byte, so the two outputs cannot drift.

## Deliberate non-goals (for now)

**No central registry**. `merelang.org`-hosted registry is planned
for v0.3+; the design work is in the project's internal notes.

**No version resolution**. `rev` pins an exact commit. If two packages
pin different revs of a shared dependency, whichever wins the walk-up
wins the import. Semver ranges are a v0.3+ concern.

**No version resolution**. If two vendored packages both bundle a
different version of `mere-http`, whichever wins the walk-up wins the
import. Sort this out at the deployment layer for now.

## Demo

`examples/pkg_demo/` is a self-contained test — one entry file and
one vendored module in `.mere_modules/hello/greet.mere`. Try:

    dune exec ./bin/mere.exe -- -w examples/pkg_demo/main.mere \
        > /tmp/pkg.wat
    wat2wasm --enable-tail-call /tmp/pkg.wat -o /tmp/pkg.wasm
    node scripts/run_wasm.js /tmp/pkg.wasm
    #   → hello, world!

## Full-path imports (Go-style, identity in the path)

To make a package's identity unambiguous, an import path may include the
package's origin, mirroring its on-disk location:

    import "github.com/owner/http/router.mere";

vendored as `.mere_modules/github.com/owner/http/router.mere`. Because the
owner is part of the path, two packages named `http` from different owners
(`github.com/a/http` vs `github.com/b/http`) live at different paths and never
collide — identity is the path, not a bare name.

### In-repo resolution via a module path

A project can declare its own module path in `mere.toml`:

    [package]
    name = "mere"
    path = "github.com/merelang/mere"

An import whose path starts with that module path resolves to **local files**,
relative to the `mere.toml` directory — so in-repo code and an external
consumer write the exact same import, the former resolving to the working tree
and the latter to a vendored `.mere_modules/` copy:

    # inside github.com/merelang/mere, contrib/http/router.mere:
    import "github.com/merelang/mere/contrib/log/log.mere";   # → ./contrib/log/log.mere

Resolution order for a relative import path is: (1) module-path-local (if it
matches the declared `path`), (2) importer-relative, (3) nearest
`.mere_modules/` walk-up, (4) `-I` / `MERE_PATH`. A project with no `path`
declared is unaffected — full-path imports simply resolve via `.mere_modules/`.

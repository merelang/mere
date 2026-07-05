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

Today, v0.1 requires manual vendoring. There is no `mere install`
yet and no central registry. Suitable methods:

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

## Deliberate non-goals (for now)

**No `mere.toml`**. Manifest / version pinning / lockfiles are the
obvious next step but out of v0.1 scope. Track a dependency by its
git URL / commit until v0.2.

**No `mere install`**. `git clone` is what you'd type anyway; adding
a wrapper doesn't save much until we have a real registry.

**No central registry**. `merelang.org`-hosted registry is planned
for v0.3+; the design work is in the project's internal notes.

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

# Mere Package Registry v0.1

Read-only JSON API for Mere packages. Runs as a Cloudflare Worker;
package data is bundled as static JSON. Future v0.2 will add
dynamic GitHub tag fetching + KV caching.

> **Note — the package repos are aspirational.** The entries in
> `packages.json` (`merelang/mere-http`, `mere-db`, `mere-json`) and
> their tarball URLs point at repos that **do not exist yet**. Today
> all contrib modules live in the `mere` monorepo under `contrib/`;
> the polyrepo split happens only when there's real demand (see the
> project's packaging notes). Don't `git clone` those URLs expecting
> a hit — this sample demonstrates the registry's API *shape*, which
> v0.2 will back with live data.

## Endpoints

| Route                     | Behaviour |
|---------------------------|-----------|
| `GET /`                   | Landing HTML with endpoint listing |
| `GET /pkg`                | Whole registry (JSON) |
| `GET /pkg/:name`          | One package's metadata (owner, description, versions map, latest) |
| `GET /pkg/:name/latest`   | Latest version's metadata (name, version, tarball URL, published_at) |
| `GET /pkg/:name/:version` | Specific version's metadata |

## Sample requests

    GET /pkg
    → {"mere-http":{...},"mere-db":{...},"mere-json":{...}}

    GET /pkg/mere-http
    → {
        "owner":       "merelang",
        "description": "HTTP server + client + middleware...",
        "repo":        "https://github.com/merelang/mere-http",
        "versions":    {"0.1.0":{"tarball":"...","published_at":"..."}},
        "latest":      "0.1.0"
      }

    GET /pkg/mere-http/latest
    → {"name":"mere-http", "version":"0.1.0",
       "tarball":"https://github.com/merelang/mere-http/archive/refs/tags/v0.1.0.tar.gz",
       "published_at":"2026-07-05T12:00:00Z"}

## What's here

- `main.mere` — routes + JSON extraction + response builder.
- `worker.js` — CF Worker entry, hands `packages.json` to the wasm
  via a `cf_registry_data ()` extern.
- `packages.json` — bundled package list. **v0.1's source of truth**.
  To add a package: edit this file + `sh build.sh` + `wrangler deploy`.
- `wrangler.toml` — CF Worker config (no KV binding for v0.1).
- `build.sh` — compile Mere → wat → wasm.
- `local_test.js` — Node smoke test with all endpoint assertions.

## Why this is a Worker (not just static hosting)

v0.1 could arguably be hosted static (packages.json served directly).
The Worker earns its keep for the API shape it presents *now* and
for the dynamic behaviour that lands *next*:

- **Endpoint normalization**: `/pkg/:name/latest` alias, header
  content-type, cross-origin headers, etc. Static hosting would
  require the client to do more parsing.
- **v0.2 growth path**: KV caching for GitHub tag lookups, dynamic
  version resolution, download-count telemetry, publish endpoint
  with auth. All of these require server compute, which static
  hosting doesn't provide.

The direction paper's rule ("use Worker only when the sample motivates
it") is satisfied by the future — the API shape is designed to
extend into v0.2 without breaking clients.

## Building + local test

    sh build.sh
    node local_test.js

The smoke test asserts 21 conditions across 8 request scenarios:
landing page, `/pkg` list, `/pkg/:name`, `/pkg/:name/latest`,
`/pkg/:name/:version`, 404s for unknown pkg / unknown version, and
"only GET" enforcement.

## Deploying

    wrangler deploy

No KV / R2 / DO bindings required for v0.1. Target subdomain
convention (once the registry is production-ready):

    pkg.merelang.org/pkg/mere-http

## v0.2 roadmap (not shipped)

- **GitHub tag fetching**: replace `packages.json` versions map with
  live `GET /repos/:owner/:name/tags` calls
- **KV cache**: 1h TTL on GitHub responses (avoid GH rate limits +
  CF edge latency)
- **Package publish endpoint**: `POST /pkg` with Bearer auth, updates
  the registry index (either KV-backed or PR-to-repo based)
- **`mere install` client**: CLI that consumes this API to populate
  `.mere_modules/` (the resolver added in the package system v0.1)

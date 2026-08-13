# contrib/url — URL handling (Mere implementation)

Percent-encoding and -decoding to the WHATWG URL Standard's sets. The parser
itself is not here yet; this is the layer under it.

## Files

| file | exports | lines |
|---|---|---|
| `percent.mere` | `module Percent { c0_control, fragment, query, special_query, path, userinfo, component, encode, decode }` | ~120 |

## Usage

```
import "contrib/url/percent.mere";

Percent.encode Percent.path "a b#c"      // "a%20b%23c"
Percent.encode Percent.component "a&b"   // "a%26b"
Percent.decode "%E3%81%82"               // "あ"
```

`encode` takes the set as a predicate on a byte, because the Standard does not
have one escaping rule — it has a stack of sets, and which one applies depends
on the component being written. The named sets are supersets of each other in
this order:

```
c0_control  ⊂  fragment
c0_control  ⊂  query  ⊂  special_query
                query  ⊂  path  ⊂  userinfo  ⊂  component
```

`special_query` is the set an http/https/ws/wss/ftp/file URL uses for its query;
`component` is for a value being placed *into* a query, where `&`, `=` and `+`
must not survive as separators.

## How the sets were checked

`sh scripts/url_parity.sh` derives each set from **node's `URL`** — an
implementation of the same specification that nobody here wrote — by putting
each byte in 0x20..0x7E alone into a component, reading the serialisation back,
and recording whether it came out as `%XX`. Ours is then diffed against that.

Derivation rather than fixtures, because a fixture file only covers the bytes
somebody thought to write down. It found two wrong sets on the first run:
`fragment` was missing `` ` `` and `path` was missing `^`.

Some bytes cannot be probed this way and the harness prints them as SKIP rather
than passing them silently: a byte that delimits the component under test ends
it instead of being escaped in it (`#` and `?` in a path), a lone space is
stripped by URL parsing before escaping happens, `.` in a path is resolved away,
and `\` is normalised to `/` for the special schemes.

`test/parity/url_percent.mere` additionally holds all four backends to the same
output.

## Not here yet

- The URL parser (scheme, host, port, path normalisation, query, fragment)
- IDNA / punycode for non-ASCII hosts
- `decode` into `bytes`. A decoded value is bytes, and a `str` holding a NUL is
  not representable on the LLVM backend, whose `str` is `strlen`-based — so
  `Percent.decode "%00"` differs by backend. Callers that can receive `%00`
  should treat this as ASCII-safe only until that is fixed.

## Relationship to `contrib/http/query.mere`

`query.mere` has had its own `url_encode` / `url_decode` since long before this,
and they are **deliberately left alone**. They implement the query-string
convention a server wants — an allowlist of `alnum -_.~`, everything else
escaped — which is not any of the Standard's sets, and changing them would
change the behaviour of every existing caller. Use those for building query
strings; use these for anything that has to agree with a browser.

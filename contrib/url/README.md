# contrib/url — URL handling (Mere implementation)

Percent-encoding to the WHATWG URL Standard's sets, and the scheme-and-authority
half of the parser. The path, query and fragment are the next slice.

## Files

| file | exports | lines |
|---|---|---|
| `percent.mere` | `module Percent { c0_control, fragment, query, special_query, path, userinfo, component, encode, decode }` | ~120 |
| `host.mere` | `type url_parts`, `module Url { parse, origin, is_special, default_port, clean, scheme_len, parse_host, parse_port, try_ipv4, ends_in_number, last_index_of }` | ~340 |

## Usage

```
import "contrib/url/host.mere";

match Url.parse "http://EXAMPLE.com:80/a" with
| Some u -> u.host ++ u.rest      // "example.com" ++ "/a" — port 80 elided
| None -> "invalid"

Percent.encode Percent.path "a b#c"      // "a%20b%23c"
Percent.decode "%E3%81%82"               // "あ"
```

`parse` returns `?url_parts` rather than failing, because rejecting input is half
of what a URL parser does — and on the wasm backend `fail` sets a flag and
returns a sentinel instead of unwinding, so a caller between the failure and its
`try_or` still runs. A rejection has to be a value.

## The two behaviours worth knowing about

Both are the kind of thing that becomes a security bug when an implementation
guesses instead of reading the standard.

**A host that parses as a number is an address, in any base.** `http://0x7f.1`
is `127.0.0.1`, and so is `http://0177.1` and `http://2130706433`. The last part
absorbs the octets nobody claimed. An allowlist that only understands dotted
decimal will pass `0x7f.1` through as a hostname and then resolve it to
localhost.

The corollary is what the oracle caught here: if the last label looks like a
number then the host *is* an address, so a bad one is **invalid** rather than a
domain with a funny name. `http://256.1.1.1` and `http://1.2.3.4.5` are not
URLs. Accepting them as hostnames was the bug.

**A domain is lowercased; an opaque host is not.** `http://EXAMPLE.com` has host
`example.com`, but `foo://EXAMPLE.com` has host `EXAMPLE.com` — case folding is a
property of the special schemes, not of hosts.

Also: the default port is elided (`http://h:80` and `http://h` have the same
origin), userinfo ends at the **last** `@` so a password may contain one, and
userinfo is percent-encoded on the way out (`http://a@b@h/` has username `a%40b`
— an unencoded `@` would re-split differently when serialised).

## How this was checked

`sh scripts/url_parity.sh` compares against **node's `URL`** — an implementation
of the same specification that nobody here wrote. Two ways:

* **The encode sets, by derivation.** Each byte in 0x20..0x7E goes alone into a
  component; the serialisation says whether it came back as `%XX`. That yields
  node's set, which is diffed against ours. Derivation rather than fixtures,
  because a fixture file only covers the bytes somebody thought to write down.
  It found `fragment` missing `` ` `` and `path` missing `^` on the first run.
* **The authority, per field.** 24 inputs, each compared as
  `scheme|user|pass|host|port` so a mismatch names the field rather than just
  the URL. Inputs node rejects must come back `None` from us too: a parser that
  accepts *more* than the oracle is the failure mode that matters for anything
  that then makes a request. This found three bugs — the two numeric hosts
  above, and the unencoded username.

Some bytes cannot be probed by derivation and the harness prints them as SKIP
rather than passing them silently: a byte that delimits the component under test
ends it instead of being escaped in it (`#` and `?` in a path), a lone space is
stripped before escaping happens, `.` in a path is resolved away, and `\` is
normalised to `/` for the special schemes.

`test/parity/url_percent.mere` and `test/parity/url_host.mere` additionally hold
all four backends to the same output. That is a separate question from
correctness and it has caught its own bug: `str_replace` returned a buffer with
no length header on the C backend, so `Url.clean` came back empty there and
every URL was rejected — with node agreeing with the interpreter the whole time.

## Not here yet

- Path normalisation (`.` / `..`), the query, and the fragment. `rest` hands
  them over untouched.
- Resolution against a base URL. Absolute URLs only.
- IPv6 parsing and re-serialisation. A literal is carried through in its
  brackets, and only checked for a closing one.
- IDNA / punycode for non-ASCII hosts.
- `decode` into `bytes`. A decoded value is bytes, and a `str` holding a NUL is
  not representable on the LLVM backend, whose `str` is `strlen`-based — so
  `Percent.decode "%00"` differs by backend. Callers that can receive `%00`
  should treat this as ASCII-safe only until that is fixed. The parser above it
  never decodes into anything it then measures.

## Relationship to `contrib/http/query.mere`

`query.mere` has had its own `url_encode` / `url_decode` since long before this,
and they are **deliberately left alone**. They implement the query-string
convention a server wants — an allowlist of `alnum -_.~`, everything else
escaped — which is not any of the Standard's sets, and changing them would
change the behaviour of every existing caller. Use those for building query
strings; use these for anything that has to agree with a browser.

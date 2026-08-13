# contrib/encoding — bytes off a wire into text (Mere implementation)

The WHATWG Encoding Standard's decoders. A page arrives as bytes and a label,
and neither is trustworthy on its own: the label may be a lie, an alias, or
absent, and the bytes may be malformed.

## Files

| file | exports | lines |
|---|---|---|
| `decode.mere` | `module Encoding { label_of, normalize_label, decode_utf8, decode_windows_1252, decode, decode_labelled, replacement }` | ~220 |
| `jis.mere` | `module Jis { decode_shift_jis, decode_euc_jp }` | ~170 |
| `jis_index.mere` | `module JisIndex { code_point_208, code_point_212 }` — **generated** | ~50 + two 35KB literals |

## Usage

```
import "contrib/encoding/decode.mere";

Encoding.decode_labelled "Shift_JIS" bytes   // label, bytes, done
Encoding.decode_utf8 bytes                   // when you know

match Encoding.label_of " UTF-8 " with
| Some name -> Encoding.decode name bytes    // None if not implemented yet
| None -> ()                                 // nobody recognises that label
```

**Decoding never fails.** Every malformed sequence becomes U+FFFD, so
`decode_utf8` returns a `str`, not an `?str`. The only thing that can fail here
is recognising a label. `decode` returns `?str` for a *different* reason — the
label named a real encoding this directory has not implemented yet — so a caller
can tell "unknown encoding" from "known but unsupported" and say so rather than
guess.

## The two counter-intuitive facts

**`ascii` means windows-1252.** So do `latin1`, `iso-8859-1`, `us-ascii` and
`ansi_x3.4-1968`. The Standard folds them all into one encoding on purpose,
because that is what the deployed web already did. A page that calls itself
`ascii` and contains byte 0x80 has a euro sign in it, not an error — and an
implementation that "helpfully" treats `ascii` as 7-bit will produce U+FFFD
where every browser produces `€`.

**How many U+FFFD a bad UTF-8 sequence produces is specified, and it is not one
per byte.**

```
F1 80 80 41   ->  U+FFFD U+0041      one error: the three bytes were a valid prefix
E0 80 80      ->  U+FFFD U+FFFD U+FFFD
```

The difference is whether the bytes could still have become something. `F1 80 80`
is a valid *prefix* of a four-byte sequence, so it is a single error together.
`E0` requires its first continuation in `A0..BF` — that bound is what makes an
overlong form unrepresentable — so `80` is not part of the sequence at all: the
sequence is one error, and then each remaining byte is reconsidered on its own
and fails on its own.

Getting this wrong changes how many characters a page has, which changes every
offset after it. It is also invisible on valid input, which is why it is swept
rather than sampled.

The same bound mechanism does all the other rejecting, with no separate checks
afterwards: `ED` requires `80..9F`, which is exactly what keeps the surrogates
unrepresentable; `F0` requires `90..BF` and `F4` requires `80..8F`, bounding the
range at both ends. `80..C1` and `F5..FF` are never lead bytes.

A leading BOM is removed, because that is what a browser does. Elsewhere in the
stream it is an ordinary character (U+FEFF).

## How this was checked

`sh scripts/encoding_parity.sh` sweeps against **node's `TextDecoder`** — an
implementation of the same specification that nobody here wrote.

| sweep | count |
|---|---|
| every single byte | 256 |
| every two-byte sequence | 65536 |
| every three-byte lead × first continuation (`E0..EF c 80`) | 4096 |
| every four-byte lead × first continuation (`F0..F4 c 80 80`) | 1280 |
| every byte through windows-1252 | 256 |
| every two-byte Shift_JIS sequence | 65536 |
| every two-byte EUC-JP sequence | 65536 |
| every `0x8F` + two-byte EUC-JP sequence | 65536 |

The two-byte sweeps are exhaustive. The three- and four-byte UTF-8 sweeps are
exhaustive **in the dimension that carries the logic** — the first continuation,
where the narrowed range lives — with the remaining bytes held at a valid value.
Neither side builds these inputs as string literals: both loop over the byte, so
there is no escaping layer to get wrong.

The first five sweeps are compared for exact equality. The three JIS sweeps are
not, and the reason is in **Why these two are not checked against node the way
the rest is** below — it is not a weakening of the gate but a different, still
exact, assertion.

**Labels are checked, not derived**, and the harness prints that gap as a SKIP
rather than implying it is covered: it confirms every label we claim maps where
we say it does, and it cannot discover a label we forgot to list.

`test/parity/encoding_decode.mere` additionally holds all four backends to the
same output.

## Byte 0x00, and the LLVM backend

A decoded 0x00 is U+0000, and on the LLVM backend a `str` is `strlen`-based, so
`str_of_codepoint 0` yields the **empty** string. The character does not truncate
the text — it **vanishes**, and every offset after it shifts by one. Measured on
this code: `41 00 42` decodes to length 3 on interp, C and Wasm, and to length 2
on LLVM.

Silent loss is worse than truncation for anything that then indexes the result,
so until a byte-safe `str` lands on that backend, treat this as safe for
0x01..0xFF only. The four-backend parity test deliberately omits 0x00 with the
reason written at the top, rather than asserting the bug.

## Shift_JIS and EUC-JP, and where the tables come from

Both are the same shape: mostly ASCII, a single-byte range for half-width
katakana, and a two-byte range whose pair becomes a *pointer* into a table. The
tables are `jis_index.mere`, which is **generated** by
`sh scripts/gen_jis_index.sh` from the Encoding Standard's own published index
files, with each file's `Identifier:` hash pinned in that script so an upstream
edit fails loudly rather than changing the tables silently.

Four details are worth knowing, all of them places an implementation can be
plausibly wrong:

* **Shift_JIS's lead offset is two numbers.** A lead below 0xA0 subtracts 0x81,
  one above subtracts 0xC1, because the single-byte katakana range 0xA1..0xDF
  sits in the middle of what would otherwise be one contiguous lead range. The
  trail skips 0x7F the same way.
* **There is a private-use window past the end of the table.** Pointers
  8836..10715, reachable from leads 0xF0..0xFC, are U+E000 onwards rather than
  errors — the vendor extensions the encoding grew.
* **An unmapped pair puts its trail byte back** if the trail was ASCII: `82 40`
  is U+FFFD then `@`, not one error swallowing two bytes. The same rule as
  UTF-8's, for the same reason — a byte that could still start something is not
  spent.
* **EUC-JP has two tables and a three-byte form.** A 0x8F lead selects JIS X 0212
  for the pair after it; 0x8E selects half-width katakana instead, in two bytes.

### Why these two are not checked against node the way the rest is

Because for these two encodings **node is not the Standard**: its `shift_jis` is
ICU's CP932. The differences were measured, not assumed:

| | |
|---|---|
| `index jis0208` | **identical** — all 8,836 slots agree |
| `index jis0212` | ICU maps **21** pointers the Standard does not, from pointer 7708 (U+2170 onwards, the small Roman numerals — NEC/IBM extensions) |
| single bytes | ICU remaps three in a cycle, 0x1A→U+001C→U+007F→U+001A, and treats 0x80 as an error where the Standard returns U+0080 |
| error recovery | ICU consumes a malformed sequence whole; the Standard puts an ASCII trail byte back |

So strict equality against node would be asserting ICU. What the harness asserts
instead is the strongest statement that survives those differences, and it is a
strong one: **the two implementations never disagree about which character a byte
sequence is.** 75,547 inputs that both call characters, all agreeing. Every
remaining difference must be either error handling (U+FFFD on at least one side)
or the named three-cycle; anything else is a table or pointer bug and fails the
gate.

Following the Standard rather than the oracle here is the same call
`contrib/url` makes, for the same reason: accepting 21 code points the Standard
does not is agreeing with an implementation instead of a specification, in the
permissive direction.

## Not here yet

- **`meta charset` sniffing.** It belongs with the HTML tokenizer rather than
  here: the algorithm is a scan for tags, and doing it twice in two places is how
  the two disagree.
- ISO-2022-JP, the UTF-16 variants, GBK, Big5, `x-user-defined`, and the
  `replacement` encoding. None of their labels are in the table yet either, so
  they come back as unrecognised rather than as known-but-unsupported — `decode`
  returning `?str` is for the state in between, when a label is added ahead of
  its decoder.
- Encoding *out*. Nothing here needs it yet — a request is bytes and a page is
  bytes, and both arrive already encoded.

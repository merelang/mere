# contrib/unicode — Unicode text segmentation (Mere implementation)

What a renderer needs before it can advance by anything a reader would call a
character.

## Files

| file | exports | lines |
|---|---|---|
| `grapheme.mere` | `module Grapheme { clusters, count, breaks_between, class_of }` | ~150 |
| `gcb_table.mere` | `module GcbTable { class_of, the 18 class constants }` — **generated** | ~40 + a 22,834-char literal |
| `linebreak.mere` | `module LineBreak { opportunities, split_lines, breaks_at, units_of }` | ~330 |
| `lb_table.mere` | `module LbTable { key_of, class_of, flags_of, the 44 class constants }` — **generated** | ~50 + a 32,625-char literal |

## Usage

```
import "contrib/unicode/grapheme.mere";

Grapheme.clusters "🇯🇵á"     // ["🇯🇵"; "á"]
Grapheme.count "👩‍👩‍👦"             // 1
Grapheme.class_of 0x200D     // GcbTable.zwj
```

## Why grapheme clusters and not code points

A grapheme cluster is what a reader calls a character, and it is what a renderer
has to advance by. `á` is one, `👩‍👩‍👦` is one, `🇯🇵` is one, `\r\n` is one. Code
points are not the unit and neither are bytes: cursor movement, selection, and
glyph advance all break in visible ways when the wrong one is used.

## The four rules that are not local

Most of UAX #29 is: look at the class of the code points on either side of a
position and decide. Four rules are not, and those four are where an
implementation goes wrong — so the walk carries exactly four pieces of state, one
per rule, and every other rule reads only the two neighbours.

| rule | what it needs beyond the neighbours |
|---|---|
| **GB12/13** flags | how many regional indicators precede, not just whether one does — `🇯🇵` is one cluster and `🇯🇵🇯` is two |
| **GB11** emoji ZWJ | whether the ZWJ was itself preceded by `ExtPict Extend*`; the ZWJ alone does not say |
| **GB9c** Indic conjuncts | whether a Linker appeared between two Consonants — added in Unicode 15.1 |
| **GB9b** Prepend | the suppression is decided by the **left** character, the only rule that looks that way |

`breaks_between` is written in UAX #29's own order so it can be checked against
the standard line by line.

## The table

`gcb_table.mere` is **generated** by `sh scripts/gen_unicode_tables.sh` from the
UCD. Three properties from three different files, folded into one class per code
point so the rules need one lookup:

| property | file | needed by |
|---|---|---|
| `Grapheme_Cluster_Break` | `auxiliary/GraphemeBreakProperty.txt` | most rules |
| `Extended_Pictographic` | `emoji/emoji-data.txt` | GB11 |
| `InCB` | `DerivedCoreProperties.txt` | GB9c |

The folding is only sound because of three facts, and the generator **asserts**
each one rather than trusting it: every `Extended_Pictographic` code point has
`Grapheme_Cluster_Break=Other` (all 2,848 of them), `InCB=Consonant` is disjoint
from the non-Other breaks, and `InCB=Linker`/`InCB=Extend` live inside `Extend`
or `ZWJ`.

1,631 ranges, fourteen characters each — six for the start, six for the end, two
for the class — with `Other` as the unstored default, which is most of the code
space. A lookup is a binary search over a fixed-width hexadecimal literal. That
shape is the one settled in `scripts/gen_jis_index.sh`, for the same reason: a
`str` is `strlen`-based on the LLVM backend, so a table has to be NUL-free, and
hex is NUL-free by construction.

**The table's Unicode version is pinned to the oracle's** (17.0). `Intl.Segmenter`
follows whatever node's ICU implements, and a table of a different vintage would
differ from it for reasons that are neither a bug nor interesting. Both the
generator and the harness assert the version, so a node upgrade fails with one
line instead of a page of diffs.

## How this was checked

`sh scripts/unicode_parity.sh` compares against node's **`Intl.Segmenter`**.
That oracle is worth more than the others in this repository: it is not a second
reading of a specification this code also reads — it is ICU, which is what
browsers ship.

8,509 inputs, none hand-picked:

| section | what it reaches |
|---|---|
| every ordered **pair** from 22 representatives | all 18 classes against each other |
| every ordered **triple** from 8 | the non-local rules at minimum length |
| every ordered **quadruple** from 7 | `ExtPict Extend ZWJ ExtPict`, `RI RI RI RI`, `C L C L` |
| **runs** of 1..8 RI, and 1..5 of each repeating shape | a pair count is not the same question as a run of six |
| both ends of **every range in the generated table** | 1,631 ranges, so a shifted or mis-parsed range shows up as a segmentation difference rather than waiting for a character nobody tested |

The corpus is generated once and written to a file that both sides read. Writing
the same list of code points twice, in two languages, is how the two lists come
to disagree.

`test/parity/grapheme.mere` additionally holds all four backends to the same
output — a separate question, and not an idle one here: the table is a
22,834-character literal read with `char_at`, so a backend whose strings behaved
differently would produce a different table rather than a different algorithm.

## Line breaking (UAX #14)

`LineBreak.opportunities` says where a line is *allowed* to end — not where it
should, which is the layout engine's decision, made with widths.

```
LineBreak.opportunities "a b"   // one bool per position, sot..eot
LineBreak.split_lines "a b"     // ["a "; "b"]
```

Forty-four numbered rules applied in order, first match wins, written in that
order so the chain can be read against the standard line by line. What makes it
long is not the rules — most look only at the two characters either side of a
position — but three things around them:

* **LB9 and LB10 are a preprocessing step, not break rules.** A combining mark
  takes the class of the character before it, so the unit the rules see is a base
  plus its trailing `CM`/`ZWJ` run. Except after a hard break or a space, where
  LB10 makes the leftover mark an `AL` of its own. The result still reports **one
  position per code point**: the positions inside a fold are exactly the ones LB9
  forbids breaking at.
* **"even after spaces" appears in six rules** (LB8, LB14, LB15a, LB15b, LB16,
  LB17), each needing the last *non-space* class as well as the immediately
  preceding one — and all six sit before LB18, which is the rule that breaks after
  a space.
* **Some rules look further than one character either way.** LB25 needs a
  number-sequence state and two of lookahead; LB15a, LB19a, LB20a, LB21a and LB28a
  need what came *before* the previous character; LB30a needs a count of preceding
  regional indicators.

`lb_table.mere` is **generated** by `sh scripts/gen_linebreak_table.sh` from four
UCD files, because several rules are written in terms of properties other than
`Line_Break`: LB15a/15b test `General_Category` Pi and Pf, LB19a and LB30 test
`East_Asian_Width`, LB30b tests an unassigned `Extended_Pictographic`. **LB1's
resolution happens in the generator** — AI/SG/XX become AL, CJ becomes NS, SA
becomes CM or AL by general category — which are the choices the UCD's own test
file assumes, and which let the rules read the way the standard writes them. CB is
deliberately left alone, because LB20 is written in terms of it.

2,175 ranges, fifteen characters each, same shape as the other tables.

### How this was checked, and how that gate differs from the others

`sh scripts/linebreak_conformance.sh` runs the **Unicode Consortium's own test
file**, 19,338 cases, vendored under `test/data` so it needs no network and cannot
drift from the table's version. All agreeing.

That is a different kind of gate from the other three in this repository, and the
difference cuts both ways:

* **Weaker**: the file is derived from the same rules the implementation reads, so
  a shared misreading of the prose would agree with itself. `Intl.Segmenter` and
  node's `URL` are independent implementations; this is not one.
* **Stronger**: it is exhaustive over the pair table — every class against every
  class, with and without an intervening combining mark and space — which no
  hand-written corpus and no sampling of another implementation would reach.

It earned its keep immediately. Three defects survived a careful reading of the
rules and were caught by cases nobody would have thought to write:

| what | how it showed |
|---|---|
| positions were reported per *unit* rather than per code point | every case containing a combining mark was one position short — 48% passing |
| **LB8a was called unreachable, and is not** | a ZWJ at the start of text has nothing to fold into, so LB10 makes it an `AL` — but LB8a comes *before* LB10, so `ZWJ ×` still applies. 25 cases |
| **LB19a's last line tests the character before the quotation mark**, not the mark | 3 cases, all of them CJK text with curly quotes |

`test/parity/linebreak.mere` additionally holds all four backends to the same
output — the table is a 32,625-character literal read with `char_at`.

## Not here yet

- **East Asian Width** (UAX #11) as an exported property. The line break table
  already carries the wide/fullwidth/halfwidth bit because LB19a and LB30 need it;
  a layout engine wants it directly, for advance widths.
- **Normalization.** `String.prototype.normalize` is an oracle for it, so it is
  gateable whenever it is needed; a renderer can draw unnormalized text, so it is
  not needed first.
- **Word and sentence segmentation.** `Intl.Segmenter` covers both granularities,
  so both are gateable. Neither is needed to draw a page.
- **Bidi** (UAX #9).

# contrib/html — the HTML tokenizer

Bytes in, tokens out, as the standard's state machine. The second half of parsing
HTML — building a tree from those tokens, with the insertion modes and the rules
that recover from mis-nesting — is a browser's job and is not here.

```
import "contrib/html/tokenizer.mere";

Html.tokenize "<p class=x>hi</p>"
// [TStart ("p", [{name="class", value="x"}], false); TChar "hi"; TEnd "p"]
```

`Html.render` prints a token list one line per token; the conformance harness
compares that text, so the canonical form is part of the library rather than a
detail of a script.

## How this is checked

**html5lib-tests**, the suite every HTML parser is measured against, maintained
alongside the specification. It is the same kind of evidence as the UCD conformance
files this repository already uses for line breaking and normalization: not
somebody's idea of what to check, but the cases the people who wrote the standard
thought were worth writing down.

```
sh scripts/html_tokenizer_conformance.sh     # 1,704 cases
```

**1,505 of 1,704 pass, and the number is pinned exactly rather than as a floor.** A
floor lets a regression hide behind a new pass; a number that has to be edited when
it moves is a number somebody looks at. The harness prints the first ten failures
in full, so what is missing is visible in the output and not only in this file.

The vendored copy of the suite is in `test/data/html5lib`, fetched by
`scripts/gen_html5lib_testdata.sh` (a maintenance command — a gate that needs the
network fails for reasons that have nothing to do with the code).

## What is not implemented yet, counted

| | cases | what it needs |
|---|--:|---|
| character references | 53 | the named entity table (2,231 entries) plus the numeric forms — the same "how do you carry a large table" question `contrib/unicode` answered |
| non-Data initial states | 111 | RCDATA / RAWTEXT / script data / PLAINTEXT: `tokenize` takes no starting state, and the tree builder is what switches it |
| U+0000 handling | 57 | the standard replaces NUL with U+FFFD in most states. Worth knowing: the harness runs on the interpreter because a Mere `str` cannot carry a NUL through the compiled backends |
| newline preprocessing | | CRLF and lone CR become LF before the tokenizer sees them |

The rest of the failures are individual spec details rather than categories, and
the harness names them.

## Why it is written this way

The standard specifies a named state per position, and this is that machine with
the same names — so a line here can be found in the specification by searching for
its state. It is not a regular expression or a lookahead scanner, because **the
recovery rules are what make HTML parseable at all** and they are stated per state:
`<`, `</`, `<!`, `<?` and a bare `&` all have defined behaviour when what follows
them is not what it looked like, and that behaviour is where the interesting bugs
are. Two of the first three failures found by the suite were exactly that shape —
a repeated attribute keeping the wrong one, and a comment ending in a lone dash.

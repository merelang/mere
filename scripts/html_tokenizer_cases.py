#!/usr/bin/env python3
"""Turn html5lib-tests into cases the tokenizer can be run over, and compare.

Two jobs, one file, because they have to agree about the canonical form of a
token and splitting them would be two places to change it.

The canonical form is one line per token:

    D<TAB>name<TAB>public<TAB>system<TAB>0|1     a missing identifier is \\N
    S<TAB>name<TAB>0|1<TAB>k=v<TAB>k=v...        attributes in source order
    E<TAB>name
    C<TAB>data
    T<TAB>data                                   adjacent characters coalesced

with backslash, tab, newline and carriage return escaped. `contrib/html`
renders exactly this, which is what makes the comparison a text diff.

Character references are not implemented yet, so a case whose expected output
contains a character the input does not is one of those — those are counted as
`entities` rather than as failures, and printed as a number so the gap is a
figure rather than a silence.
"""

import json
import os
import sys


def esc(s):
    out = []
    for ch in s:
        if ch == "\\":
            out.append("\\\\")
        elif ch == "\t":
            out.append("\\t")
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        else:
            out.append(ch)
    return "".join(out)


def esc_input(s):
    """As esc, plus every other control character as \\xHH: a case file is one
    line per case, and a raw control character in one would end it early."""
    out = []
    for ch in s:
        if ch == "\\":
            out.append("\\\\")
        elif ch == "\t":
            out.append("\\t")
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ord(ch) < 0x20 or ord(ch) == 0x7F:
            out.append("\\x%02x" % ord(ch))
        else:
            out.append(ch)
    return "".join(out)


def render_expected(tokens):
    """html5lib's expected output in the canonical form, with adjacent Character
    tokens joined the way the suite's own README says they may be split."""
    lines = []
    for t in tokens:
        kind = t[0]
        if kind == "DOCTYPE":
            _, name, pub, sysid, correct = t
            lines.append(
                "D\t%s\t%s\t%s\t%s"
                % (
                    esc(name or ""),
                    "\\N" if pub is None else esc(pub),
                    "\\N" if sysid is None else esc(sysid),
                    "1" if correct else "0",
                )
            )
        elif kind == "StartTag":
            name, attrs = t[1], t[2]
            selfc = len(t) > 3 and t[3]
            row = "S\t%s\t%s" % (esc(name), "1" if selfc else "0")
            for k, v in attrs.items():
                row += "\t%s=%s" % (esc(k), esc(v))
            lines.append(row)
        elif kind == "EndTag":
            lines.append("E\t%s" % esc(t[1]))
        elif kind == "Comment":
            lines.append("C\t%s" % esc(t[1]))
        elif kind == "Character":
            if lines and lines[-1].startswith("T\t"):
                lines[-1] += esc(t[1])
            else:
                lines.append("T\t%s" % esc(t[1]))
        else:
            lines.append("?\t%s" % kind)
    return "\n".join(lines)


def collect(data_dir):
    """Every case, with why it is being skipped if it is."""
    cases = []
    for name in sorted(os.listdir(data_dir)):
        if not name.endswith(".test"):
            continue
        with open(os.path.join(data_dir, name), encoding="utf-8") as fh:
            doc = json.load(fh)
        for t in doc.get("tests", []):
            skip = "double-escaped" if t.get("doubleEscaped") else None
            # A case listed under several initial states is several cases: the
            # suite writes it once and means it for each, and running only the
            # first would report a number smaller than what was checked.
            for st in (t.get("initialStates") or ["Data state"]):
                cases.append(
                    {
                        "file": name,
                        "desc": "%s [%s]" % (t.get("description", ""), st),
                        "state": st,
                        "last": t.get("lastStartTag", ""),
                        "input": t.get("input", ""),
                        "output": t.get("output", []),
                        "skip": skip,
                    }
                )
    return cases


def has_entity(case):
    """Cases the tokenizer cannot pass because it does not decode `&...;` yet.
    A conservative test — an ampersand in the input and not in the output."""
    if "&" not in case["input"]:
        return False
    text = "".join(
        t[1] for t in case["output"] if t and t[0] == "Character"
    ) + "".join(
        "".join(t[2].values()) for t in case["output"] if t and t[0] == "StartTag"
    )
    return "&" not in text or case["input"].count("&") > text.count("&")


def main_generate(data_dir, cases_path, expected_path, meta_path):
    cases = collect(data_dir)
    with open(cases_path, "w", encoding="utf-8") as cf, open(
        expected_path, "w", encoding="utf-8"
    ) as ef, open(meta_path, "w", encoding="utf-8") as mf:
        for i, c in enumerate(cases):
            # Every case gets a line so the indices line up; a skipped one is run
            # anyway and its result ignored, which keeps the two files in step.
            cf.write("%s\t%s\t%s\n" % (c["state"], c["last"], esc_input(c["input"])))
            ef.write("##%d\n%s\n" % (i, render_expected(c["output"])))
            reason = c["skip"] or ("entities" if has_entity(c) else "")
            mf.write("%s\t%s\t%s\n" % (reason, c["file"], c["desc"]))
    print("html_tokenizer: %d cases from %s" % (len(cases), data_dir))


def read_blocks(path):
    blocks = {}
    cur = None
    for line in open(path, encoding="utf-8").read().split("\n"):
        if line.startswith("##"):
            cur = int(line[2:])
            blocks[cur] = []
        elif cur is not None:
            blocks[cur].append(line)
    # A trailing "0" from the program's own exit value is not a token line.
    return {k: "\n".join(v).strip("\n") for k, v in blocks.items()}


def main_compare(expected_path, got_path, meta_path, expect_pass):
    expected = read_blocks(expected_path)
    got = read_blocks(got_path)
    meta = [l.split("\t", 2) for l in open(meta_path, encoding="utf-8").read().split("\n") if l]

    passed = failed = 0
    by_reason = {}
    unexpected = []
    for i, (reason, fname, desc) in enumerate(meta):
        exp = expected.get(i, "")
        act = got.get(i, "")
        # The last block picks up the program's own trailing value.
        if act.endswith("\n0"):
            act = act[:-2]
        elif act == "0":
            act = ""
        ok = exp == act
        if reason:
            by_reason[reason] = by_reason.get(reason, 0) + 1
            if ok:
                passed += 1
            continue
        if ok:
            passed += 1
        else:
            failed += 1
            if len(unexpected) < 10:
                unexpected.append((fname, desc, exp, act))

    total = len(meta)
    print("html_tokenizer: %d passed, %d failed, of %d cases" % (passed, failed, total))
    for k in sorted(by_reason):
        print("  not covered yet: %-16s %d" % (k, by_reason[k]))
    for fname, desc, exp, act in unexpected:
        print("  FAIL %s: %s" % (fname, desc))
        print("    expected: %s" % exp.replace("\n", " | "))
        print("    got:      %s" % act.replace("\n", " | "))

    if passed != int(expect_pass):
        print(
            "html_tokenizer: expected exactly %s passing, got %d — "
            "raise EXPECT_PASS in the harness if this is the tokenizer growing"
            % (expect_pass, passed)
        )
        return 1
    print("html_tokenizer: ok")
    return 0


if __name__ == "__main__":
    if sys.argv[1] == "--compare":
        sys.exit(main_compare(*sys.argv[2:]))
    main_generate(*sys.argv[1:])

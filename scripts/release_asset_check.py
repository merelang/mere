#!/usr/bin/env python3
"""Reject release binaries containing credentials or home-directory paths."""
import argparse
from pathlib import Path
import re
import sys

LIMIT = 32 * 1024 * 1024
MAGIC = (b"\x7fELF", b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf")
RULES = {
    "home-path": rb"/(?:Users|home)/[^\x00/\s\"'<>]+",
    "windows-home-path": rb"(?i)[a-z]:[\\/]+Users[\\/]+[^\x00\\/\s\"'<>]+",
    "private-key": rb"-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----",
    "github-token": rb"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{30,})\b",
    "aws-access-key": rb"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b",
    "slack-token": rb"\bxox[baprs]-[A-Za-z0-9-]{16,}",
    "api-token": rb"\b(?:sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{20,}|AIza[A-Za-z0-9_-]{35})\b",
    "credential-assignment": rb"(?i)\b(?:password|passwd|api[_-]?key|access[_-]?token|client[_-]?secret)\b[\"']?\s*[:=]\s*[\"'][^\x00\r\n\"']{8,}[\"']",
}
PATTERNS = {name: re.compile(pattern) for name, pattern in RULES.items()}


def findings(data):
    result = set()
    if not data.startswith(MAGIC):
        result.add("binary-format")
    views = [data]
    if b"\x00" in data:
        views += [data.decode(enc, errors="replace").encode("utf-8")
                  for enc in ("utf-16-le", "utf-16-be")]
    for name, pattern in PATTERNS.items():
        if any(pattern.search(view) for view in views):
            result.add(name)
    return result


def self_test():
    header = MAGIC[0] + b"\x00" * 28
    token = b"gh" + b"p_" + b"AB12" * 10
    cases = [
        (header, set()),
        (MAGIC[1] + b"\x00" * 28, set()),
        (b"not a binary", {"binary-format"}),
        (header + token, {"github-token"}),
        (header + token.decode().encode("utf-16-le"), {"github-token"}),
        (header + b"AK" + b"IA" + b"A1" * 8, {"aws-access-key"}),
        (header + b"sk" + b"-proj-" + b"AB12" * 10, {"api-token"}),
        (header + b"-----BEGIN " + b"RSA PRIVATE KEY-----", {"private-key"}),
        (header + b"/" + b"home" + b"/runner/build", {"home-path"}),
        (header + b"/" + b"Users" + b"/runner/build", {"home-path"}),
        (header + b"C:" + b"\\Users" + b"\\runner\\build", {"windows-home-path"}),
        (header + b"api" + b"_key=\"" + b"AB12" * 10 + b"\"", {"credential-assignment"}),
    ]
    for data, expected in cases:
        if findings(data) != expected:
            print("release asset check: self-test failed", file=sys.stderr)
            return 1
    print("release asset check: {} self-tests passed".format(len(cases)))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("assets", nargs="*")
    args = parser.parse_args()
    if args.self_test and self_test():
        return 1
    if not args.assets:
        if args.self_test:
            return 0
        parser.error("provide an asset or --self-test")
    for name in args.assets:
        try:
            path = Path(name)
            if not 0 < path.stat().st_size <= LIMIT:
                raise ValueError()
            found = findings(path.read_bytes())
        except (OSError, ValueError):
            print("release asset check: unreadable, empty or oversized input", file=sys.stderr)
            return 2
        if found:
            print("release asset check: rejected ({})".format(", ".join(sorted(found))), file=sys.stderr)
            return 1
    print("release asset check: {} binaries passed".format(len(args.assets)))
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Configure bounded package downloads on an ephemeral Ubuntu CI runner."""
from pathlib import Path
import re
import sys


def configure(root):
    if not root.is_dir():
        raise ValueError("APT configuration directory does not exist")
    sources = [root / "sources.list"]
    directory = root / "sources.list.d"
    sources += sorted(directory.glob("*.list")) + sorted(directory.glob("*.sources"))
    updated = 0
    for source in sources:
        if not source.is_file():
            continue
        text = source.read_text()
        replacement = re.sub(
            r"https?://azure\.archive\.ubuntu\.com/ubuntu(?=[/\s]|$)",
            "https://archive.ubuntu.com/ubuntu", text)
        if replacement != text:
            source.write_text(replacement)
            updated += 1
    config = root / "apt.conf.d"
    config.mkdir(exist_ok=True)
    (config / "80mere-downloads").write_text(
        'Acquire::Retries "2";\n'
        'Acquire::http::Timeout "30";\n'
        'Acquire::https::Timeout "30";\n')
    return updated


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: ci_apt_setup.py <apt-configuration-directory>")
    print("ci_apt_setup: configured download bounds; updated {} source files".format(
        configure(Path(sys.argv[1]))))

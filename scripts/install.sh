#!/bin/sh
# Install a prebuilt `mere` binary from the latest GitHub Release.
#
#   curl -fsSL https://raw.githubusercontent.com/merelang/mere/main/scripts/install.sh | sh
#
# Override the install directory with MERE_BINDIR (default: ~/.local/bin).
# No OCaml toolchain required. Falls back to build-from-source instructions
# on unsupported platforms.

set -eu

REPO="merelang/mere"
BINDIR="${MERE_BINDIR:-$HOME/.local/bin}"

os="$(uname -s)"
arch="$(uname -m)"

case "$os" in
  Linux)
    case "$arch" in
      x86_64 | amd64) asset="mere-linux-x86_64" ;;
      *) os_unsupported=1 ;;
    esac
    ;;
  Darwin)
    case "$arch" in
      arm64) asset="mere-macos-arm64" ;;
      x86_64) asset="mere-macos-x86_64" ;;
      *) os_unsupported=1 ;;
    esac
    ;;
  *) os_unsupported=1 ;;
esac

if [ "${os_unsupported:-0}" = "1" ]; then
  echo "No prebuilt binary for $os/$arch." >&2
  echo "Build from source: git clone https://github.com/$REPO && cd mere && opam install . --deps-only && dune build" >&2
  exit 1
fi

url="https://github.com/$REPO/releases/latest/download/$asset"

echo "Installing mere ($asset) to $BINDIR/mere"
mkdir -p "$BINDIR"
if ! curl -fSL "$url" -o "$BINDIR/mere"; then
  echo "download failed: $url" >&2
  echo "(has a release been published yet? see https://github.com/$REPO/releases)" >&2
  exit 1
fi
chmod +x "$BINDIR/mere"

echo "Installed: $("$BINDIR/mere" -v 2>/dev/null || echo "$BINDIR/mere")"
case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *) echo "Add $BINDIR to your PATH:  export PATH=\"$BINDIR:\$PATH\"" ;;
esac

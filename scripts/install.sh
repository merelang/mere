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
      # macOS x86_64 is NOT built -- see the matrix in .github/workflows/
      # release.yml. This script used to name the asset anyway, so an Intel
      # Mac got a 404 and a message asking whether a release had been
      # published: releases exist, that platform is not in them. An install
      # script that names an artifact nobody builds is a claim, not a path.
      # scripts/first_run_check.sh now holds the two files to each other.
      x86_64) os_unsupported=1 ;;
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

die() {
  echo "mere install: $*" >&2
  exit 1
}

if command -v sha256sum >/dev/null 2>&1; then
  checksum() { sha256sum "$1"; }
elif command -v shasum >/dev/null 2>&1; then
  checksum() { shasum -a 256 "$1"; }
else
  die "sha256sum or shasum is required to verify the download"
fi

# Resolve latest once: the binary and its checksum must belong to one release,
# even if another release is published while this script is running.
release_url="$(curl -fsSL -o /dev/null -w '%{url_effective}' \
  "https://github.com/$REPO/releases/latest")" || die "could not resolve the latest release"
case "$release_url" in
  "https://github.com/$REPO/releases/tag/"*) ;;
  *) die "unexpected release URL" ;;
esac
tag="${release_url##*/}"
version="$(printf '%s\n' "$tag" | sed -n 's/^v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$/\1/p')"
[ -n "$version" ] || die "unexpected release tag"
url="https://github.com/$REPO/releases/download/$tag"

echo "Installing mere $tag ($asset) to $BINDIR/mere"
mkdir -p "$BINDIR"
[ ! -d "$BINDIR/mere" ] || die "the destination is a directory"
# Stage on the destination filesystem so the final rename is atomic.
staging="$(mktemp -d "$BINDIR/.mere-install.XXXXXX")" || die "could not create a staging directory"
trap 'rm -rf "$staging"' 0
trap 'exit 1' 1 2 15

curl -fSL "$url/SHA256SUMS" -o "$staging/SHA256SUMS" || die "checksum download failed"
curl -fSL "$url/$asset" -o "$staging/$asset" || die "binary download failed"
expected="$(awk -v asset="$asset" '$2 == asset { print tolower($1) }' "$staging/SHA256SUMS")"
case "$expected" in
  ''|*[!0-9a-f]*) die "missing or invalid checksum for $asset" ;;
esac
[ "${#expected}" -eq 64 ] || die "missing, duplicate or invalid checksum for $asset"
hashed="$(checksum "$staging/$asset")" || die "checksum verification failed"
actual="$(printf '%s\n' "$hashed" | awk '{ print $1 }')"
[ "$actual" = "$expected" ] || die "checksum mismatch for $asset"

chmod 755 "$staging/$asset"
got="$("$staging/$asset" --version)" || die "the downloaded binary cannot run"
[ "$got" = "mere v$version" ] || die "the binary version does not match $tag"
printf 'let _ = print "install-ok";\n' > "$staging/smoke.mere"
out="$("$staging/$asset" "$staging/smoke.mere")" || die "the downloaded binary could not run a program"
[ "$out" = "install-ok" ] || die "the downloaded binary returned an unexpected result"

mv -f "$staging/$asset" "$BINDIR/mere"
echo "Installed: $got"
case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *) echo "Add $BINDIR to your PATH:  export PATH=\"$BINDIR:\$PATH\"" ;;
esac

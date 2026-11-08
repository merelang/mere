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

fetch() {
  curl --connect-timeout 20 --max-time 180 -fsSL "$@"
}
api_asset_id() {
  # Tokenize strings before structural punctuation, so quoted release notes,
  # escaped quotes and nested uploader objects cannot impersonate asset fields.
  # Only plain numeric IDs and the exact asset/tag names are accepted.
  awk -v wanted="$1" -v tag="${tag:-}" '
    function token(value, kind) {
      if (kind == "string") {
        if (pending != "") {
          if (depth == 1 && pending == "tag_name") { release_tag = value; tags++ }
          if (depth == 3 && assets == 2 && pending == "name") name = value
          pending = ""
        } else last = value
      } else if (value == ":") { pending = last; last = "" }
      else if (value == "{" || value == "[") {
        if (value == "[" && depth == 1 && pending == "assets") assets = 2
        pending = ""; stack[++depth] = value
        if (depth == 3 && assets == 2 && value == "{") { id = ""; name = "" }
      } else if (value == "}" || value == "]") {
        if (depth < 1 || stack[depth] != (value == "}" ? "{" : "[")) bad = 1
        if (depth == 3 && assets == 2 && value == "}" && name == wanted) {
          if (id !~ /^[1-9][0-9]*$/) bad = 1
          found++; result = id
        }
        if (depth == 2 && value == "]") assets = 0
        delete stack[depth--]; pending = ""
      } else if (value == ",") { pending = ""; last = "" }
      else {
        if (depth == 3 && assets == 2 && pending == "id") id = value
        pending = ""
      }
    }
    {
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (quoted) {
          if (escaped) { text = text "\\" c; escaped = 0 }
          else if (c == "\\") escaped = 1
          else if (c == "\"") { quoted = 0; token(text, "string"); text = "" }
          else text = text c
        } else if (c == "\"") { quoted = 1; text = "" }
        else if (c ~ /[{}\[\]:,]/) token(c, "punctuation")
        else if (c !~ /[[:space:]]/) {
          value = c
          while (i < length($0) && substr($0, i + 1, 1) !~ /[[:space:]{}\[\]:,]/)
            value = value substr($0, ++i, 1)
          token(value, "literal")
        }
      }
      if (quoted) bad = 1
    }
    END {
      if (bad || quoted || depth != 0 || tags != 1) exit 1
      if (wanted == "") { print release_tag; exit }
      if (found != 1 || release_tag != tag) exit 1
      print result
    }
  '
}
# Resolve latest once: the binary and its checksum must belong to one release,
# even if another release is published while this script is running.
if release_url="$(fetch -o /dev/null -w '%{url_effective}' \
  "https://github.com/$REPO/releases/latest")"; then
  case "$release_url" in
    "https://github.com/$REPO/releases/tag/"*) ;;
    *) die "unexpected release URL" ;;
  esac
  tag="${release_url##*/}"
else
  metadata="$(fetch "https://api.github.com/repos/$REPO/releases/latest")" \
    || die "could not resolve the latest release"
  tag="$(printf '%s\n' "$metadata" | api_asset_id "")" \
    || die "invalid latest release metadata"
fi
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

# Public asset redirects can fail while the official release API still serves
# the same bytes. Keep both downloads pinned to the already resolved tag.
download() {
  name=$1
  if fetch "$url/$name" -o "$staging/$name"; then return; fi
  echo "Trying the official release API for $name" >&2
  if [ ! -f "$staging/release.json" ]; then
    fetch "https://api.github.com/repos/$REPO/releases/tags/$tag" \
      -o "$staging/release.json" || return 1
  fi
  id="$(api_asset_id "$name" < "$staging/release.json")" || return 1
  fetch -H 'Accept: application/octet-stream' \
    "https://api.github.com/repos/$REPO/releases/assets/$id" -o "$staging/$name"
}
download SHA256SUMS || die "checksum download failed"
download "$asset" || die "binary download failed"
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

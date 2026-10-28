#!/bin/sh
# One-line installer: sh install-kogen.sh [--version <tag>] [--prefix <dir>] [--from <dir>]
set -eu
version=""; prefix="$HOME/.local"; from=""
while [ $# -gt 0 ]; do
  case "$1" in
    --version) [ $# -ge 2 ] || { echo "install-kogen: --version needs a value"; exit 2; }; version=$2; shift 2 ;;
    --prefix) [ $# -ge 2 ] || { echo "install-kogen: --prefix needs a value"; exit 2; }; prefix=$2; shift 2 ;;
    --from) [ $# -ge 2 ] || { echo "install-kogen: --from needs a value"; exit 2; }; from=$2; shift 2 ;;
    *) echo "install-kogen: unexpected argument '$1'"; exit 2 ;;
  esac
done
[ -z "$from" ] || [ -n "$version" ] || { echo "install-kogen: --from needs --version"; exit 2; }

arch=$(uname -m)
case "$arch" in aarch64|arm64) arch=arm64 ;; x86_64|amd64) arch=x86_64 ;; esac
platform="$(uname -s | tr '[:upper:]' '[:lower:]')-$arch"
case "$platform" in
  darwin-arm64|darwin-x86_64|linux-x86_64|linux-arm64) ;;
  *) echo "install-kogen: unsupported platform $platform"; exit 1 ;;
esac

tmp=$(mktemp -d "${TMPDIR:-/tmp}/kogen-install.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' HUP INT TERM

if [ -z "$from" ] && [ -z "$version" ]; then
  version=$(curl -fsSL https://api.github.com/repos/KogenAI/kogen/releases/latest | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
  [ -n "$version" ] || { echo "install-kogen: could not find the latest release"; exit 1; }
fi
archive="kogen-$version-$platform.tar.gz"
if [ -n "$from" ]; then
  cp "$from/$archive" "$from/SHA256SUMS" "$tmp/"
else
  base="https://github.com/KogenAI/kogen/releases/download/$version"
  curl -fsSL -o "$tmp/$archive" "$base/$archive"
  curl -fsSL -o "$tmp/SHA256SUMS" "$base/SHA256SUMS"
fi

expected=$(awk -v f="$archive" '$2 == f || $2 == "*" f { print $1; exit }' "$tmp/SHA256SUMS")
if command -v sha256sum >/dev/null 2>&1; then actual=$(sha256sum "$tmp/$archive" | cut -d' ' -f1)
else actual=$(shasum -a 256 "$tmp/$archive" | cut -d' ' -f1); fi
if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
  echo "install-kogen: checksum mismatch for $archive (expected ${expected:-none}, got $actual); refusing to install"
  exit 1
fi

mkdir "$tmp/x"
tar -xzf "$tmp/$archive" -C "$tmp/x"
sh "$tmp/x/kogen-$version-$platform/install.sh" --prefix "$prefix"
prefix=$(cd "$prefix" && pwd)
(cd / && "$prefix/bin/kogen" version)

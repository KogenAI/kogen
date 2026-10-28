#!/bin/sh
# Builds the release set: sh packaging/release.sh --version <v> --output <dir>
# Writes the four platform archives, SHA256SUMS and install-kogen.sh into <dir>.
set -eu
src=$(cd "$(dirname "$0")/.." && pwd)
cd "$src"
version=""; output=""
while [ $# -gt 0 ]; do
  case "$1" in
    --version) [ $# -ge 2 ] || { echo "release: --version needs a value"; exit 2; }; version=$2; shift 2 ;;
    --output) [ $# -ge 2 ] || { echo "release: --output needs a value"; exit 2; }; output=$2; shift 2 ;;
    *) echo "release: unexpected argument '$1'"; exit 2 ;;
  esac
done
[ -n "$version" ] && [ -n "$output" ] || { echo "release: usage: release.sh --version <v> --output <dir>"; exit 2; }

if [ -n "$(git status --porcelain --untracked-files=all -- LICENSE NOTICE cli packaging docs)" ]; then
  echo "release: the checkout is not clean (uncommitted or untracked changes under LICENSE NOTICE cli packaging docs); check out the tag cleanly first"
  exit 1
fi

mkdir -p "$output"
output=$(cd "$output" && pwd)
for t in darwin-arm64 darwin-x86_64 linux-x86_64 linux-arm64; do
  archive=$(sh packaging/package.sh --version "$version" --target "$t" | tail -n 1)
  cp "$archive" "$output/"
done
cp packaging/install-kogen.sh "$output/install-kogen.sh"
(
  cd "$output"
  if command -v sha256sum >/dev/null 2>&1; then sha256sum kogen-"$version"-*.tar.gz > SHA256SUMS
  else shasum -a 256 kogen-"$version"-*.tar.gz | sed 's/ \*/  /' > SHA256SUMS; fi
)

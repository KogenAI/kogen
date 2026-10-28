#!/bin/sh
# Installs kogen for this user (INS-4): sh install.sh [--prefix <dir>]   (default $HOME/.local)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
prefix="$HOME/.local"
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) [ $# -ge 2 ] || { echo "install: --prefix needs a value"; exit 2; }; prefix=$2; shift 2 ;;
    --prefix=*) prefix=${1#--prefix=}; shift ;;
    *) echo "install: unexpected argument '$1'"; exit 2 ;;
  esac
done

arch=$(uname -m)
case "$arch" in aarch64|arm64) arch=arm64 ;; x86_64|amd64) arch=x86_64 ;; esac
platform="$(uname -s | tr '[:upper:]' '[:lower:]')-$arch"
case "$platform" in
  darwin-arm64|darwin-x86_64|linux-x86_64|linux-arm64) ;;
  *) echo "install: unsupported platform $platform"; exit 1 ;;
esac
target=$(cat "$here/TARGET")
[ "$platform" = "$target" ] || { echo "install: this archive is for $target, not $platform"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "install: kogen needs git; install git first"; exit 1; }

mkdir -p "$prefix"
prefix=$(cd "$prefix" && pwd)
lib="$prefix/lib/kogen"
rm -rf "$lib"
mkdir -p "$lib" "$prefix/bin"
cp -R "$here/bin" "$here/docs" "$here/lib" "$here/licenses" "$here/README.md" "$here/LICENSE" "$here/NOTICE" "$lib/"

# Kogen runs Quint and the acceptance bridge (Cucumber 13.3.0) with its own Node: node 22 or newer
# from PATH, else the current LTS.
node=$(command -v node 2>/dev/null || true)
if [ -n "$node" ] && [ "$("$node" -p 'process.versions.node.split(".")[0] >= 22' 2>/dev/null || true)" = "true" ]; then
  node=$("$node" -p process.execPath)
else
  case "$platform" in darwin-arm64) dist=darwin-arm64 ;; darwin-x86_64) dist=darwin-x64 ;; linux-x86_64) dist=linux-x64 ;; linux-arm64) dist=linux-arm64 ;; esac
  lts=$(curl -fsSL https://nodejs.org/dist/index.tab | awk -F'\t' 'NR > 1 && $10 != "-" && !v { v = $1 } END { print v }')
  [ -n "$lts" ] || { echo "install: could not find the current Node LTS at nodejs.org"; exit 1; }
  mkdir -p "$lib/node"
  curl -fsSL "https://nodejs.org/dist/$lts/node-$lts-$dist.tar.gz" | tar -xz -C "$lib/node" --strip-components 1
  node="$lib/node/bin/node"
fi
printf '%s\n' "$node" > "$lib/node-path"

ln -sf "$lib/bin/kogen" "$prefix/bin/kogen"
if ! out=$(cd / && "$prefix/bin/kogen" version 2>&1); then
  printf '%s\n' "$out"
  exit 1
fi
case ":$PATH:" in
  *":$prefix/bin:"*) ;;
  *) echo "Add to PATH: export PATH=\"$prefix/bin:\$PATH\"" ;;
esac
echo "Installed kogen $(printf '%s' "$out" | cut -d' ' -f2) in $prefix"

#!/bin/sh
# Update the tap from verified release assets: <tag> <tap-checkout> <assets-directory>
set -eu
trap 'echo "Homebrew tap update failed (check updater, checksum and Git errors above)" >&2' 0
[ "$#" -eq 3 ] || { echo "Homebrew: expected tag, tap checkout and release assets directory" >&2; exit 2; }
tag=$1
tap=$(cd "$2" && pwd)
assets=$(cd "$3" && pwd)

checksum() {
  name="kogen-$tag-$1.tar.gz"
  expected=$(awk -v name="$name" '$2 == name || $2 == "*" name { print $1 }' "$assets/SHA256SUMS")
  case "$expected" in
    *[!0123456789abcdefABCDEF]*|'') echo "Homebrew checksum missing or invalid: $name" >&2; return 1 ;;
  esac
  [ "${#expected}" -eq 64 ] || { echo "Homebrew checksum invalid: $name" >&2; return 1; }
  actual=$(shasum -a 256 "$assets/$name")
  actual=${actual%% *}
  [ "$actual" = "$expected" ] || { echo "Homebrew checksum mismatch: $name" >&2; return 1; }
  printf '%s\n' "$expected"
}
darwin=$(checksum darwin-arm64)
linux=$(checksum linux-x86_64)
(cd "$tap" && sh scripts/update-formula.sh "$tag" "$darwin" "$linux")
# Do not publish a formula if the tap updater failed to apply the requested release.
awk -v tag="$tag" -v darwin="$darwin" -v linux="$linux" '
  BEGIN { version = tag; sub(/^v/, "", version); base = "https://github.com/KogenAI/kogen/releases/download/" tag "/kogen-" tag "-" }
  $1 == "version" && $2 == "\"" version "\"" { v = 1 }
  $1 == "url" { target = ""; if ($2 == "\"" base "darwin-arm64.tar.gz\"") target = "darwin"; if ($2 == "\"" base "linux-x86_64.tar.gz\"") target = "linux" }
  $1 == "sha256" && target == "darwin" && $2 == "\"" darwin "\"" { d = 1; target = "" }
  $1 == "sha256" && target == "linux" && $2 == "\"" linux "\"" { l = 1; target = "" }
  END { if (!v || !d || !l) { print "Homebrew tap formula does not match release" > "/dev/stderr"; exit 1 } }
' "$tap/Formula/kogen.rb"
git -C "$tap" add Formula/kogen.rb
if ! git -C "$tap" diff --cached --quiet -- Formula/kogen.rb; then
  git -C "$tap" commit -m "Update kogen to $tag" -- Formula/kogen.rb
fi
branch=$(git -C "$tap" symbolic-ref --short HEAD)
git -C "$tap" push origin "HEAD:refs/heads/$branch"
trap - 0

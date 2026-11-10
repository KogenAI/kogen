set -eu
if [ $# -ne 3 ]; then exit 2; fi
formula="$(dirname "$0")/../Formula/kogen.rb"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
awk -v tag="$1" -v arm64="$2" -v amd64="$3" '
BEGIN { base = "https://github.com/KogenAI/kogen/releases/download/" tag "/kogen-" tag "-"; ver = tag; sub(/^v/, "", ver) }
{ indent = $0; sub(/[^ \t].*$/, "", indent) }
/^[ \t]*url "[^"]*-darwin-arm64\.tar\.gz"/ { print indent "url \"" base "darwin-arm64.tar.gz\""; sha = arm64; next }
/^[ \t]*url "[^"]*-linux-x86_64\.tar\.gz"/ { print indent "url \"" base "linux-x86_64.tar.gz\""; sha = amd64; next }
/^[ \t]*url "/ { sha = "" }
sha != "" && /^[ \t]*sha256 "/ { print indent "sha256 \"" sha "\""; sha = ""; next }
/^[ \t]*version "/ { print indent "version \"" ver "\""; next }
{ print }
' "$formula" >"$tmp"
cat "$tmp" >"$formula"

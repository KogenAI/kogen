#!/bin/sh
# Copies a kogen-loop checkout into cli/third_party/kogen-loop and rewrites cli/loop-pin.json.
# This is the only writer of that copy: a kogen-loop change reaches Kogen as one reviewable
# diff (copied files + pin). Usage: sh packaging/sync-kogen-loop.sh /path/to/kogen-loop
# Files: tracked and untracked-but-not-ignored component files, excluding .git and
# Kogen's .kogen/ configuration/evidence and features/ acceptance harness; the digest is
# sha256 over the sorted lines "path NUL sha256(file) LF" (cli/loop_pin_test.go recomputes it).
set -eu
src="${1:?usage: sync-kogen-loop.sh KOGEN_LOOP_CHECKOUT}"
root="$(cd "$(dirname "$0")/.." && pwd)"
dest="$root/cli/third_party/kogen-loop"
src="$(cd "$src" && pwd)"
[ -f "$src/go.mod" ] && grep -q '^module github.com/KogenAI/kogen-loop$' "$src/go.mod" || { echo "sync: $src is not a kogen-loop module" >&2; exit 2; }
# Read the compiled API constants; Protocol may be a Go constant expression.
identity=$(mktemp "${TMPDIR:-/tmp}/kogen-loop-identity.XXXXXX.go")
trap 'rm -f "$identity"' EXIT HUP INT TERM
cat > "$identity" <<'GO'
package main
import (
  "fmt"
  "github.com/KogenAI/kogen-loop/api"
)
func main() { fmt.Println(api.Protocol); fmt.Println(api.Library) }
GO
ids=$(cd "$src" && go run "$identity")
protocol=$(printf '%s\n' "$ids" | sed -n '1p')
library=$(printf '%s\n' "$ids" | sed -n '2p')
[ -n "$protocol" ] && [ -n "$library" ] || { echo "sync: missing API identity" >&2; exit 2; }
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }
list="$(cd "$src" && git ls-files --cached --others --exclude-standard | awk '!/^\.kogen\// && !/^features\//' | LC_ALL=C sort -u)"
[ -n "$list" ] || { echo "sync: no files in $src" >&2; exit 2; }
rm -rf "$dest"
mkdir -p "$dest"
printf '%s\n' "$list" | while IFS= read -r f; do
  [ -f "$src/$f" ] || continue
  mkdir -p "$dest/$(dirname "$f")"
  cp "$src/$f" "$dest/$f"
  chmod 0644 "$dest/$f"
done
digest="$(cd "$dest" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | while IFS= read -r f; do
  printf '%s\0%s\n' "$f" "$(sha < "$f")"; done | sha)"
count="$(cd "$dest" && find . -type f | wc -l | tr -d ' ')"
head="$(git -C "$src" rev-parse --verify -q HEAD 2>/dev/null || echo unborn)"
state=clean
[ -z "$(git -C "$src" status --porcelain --untracked-files=all)" ] || state=uncommitted
cat > "$root/cli/loop-pin.json" <<EOF
{
  "module": "github.com/KogenAI/kogen-loop",
  "protocol": "$protocol",
  "library": "$library",
  "digest": "$digest",
  "files": $count,
  "source_head": "$head",
  "source_state": "$state"
}
EOF
echo "synced $count files, digest $digest (source $head, $state)"

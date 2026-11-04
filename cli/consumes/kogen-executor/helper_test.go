package consumes

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/KogenAI/kogen-executor/executor/claudecode"
)

// fakeRuntime installs a synthetic `claude` at claudecode.RuntimePath(home): a POSIX sh script
// that answers --version with the given line and `auth status --json` with a claude.ai sign-in.
// Nothing is downloaded and no real Claude Code runs.
func fakeRuntime(t testing.TB, home, version string) string {
	t.Helper()
	script := `#!/bin/sh
if [ "$1" = "--version" ]; then
  echo ` + shQuote(version) + `
  exit 0
fi
if [ "$1" = "auth" ] && [ "$2" = "status" ] && [ "$3" = "--json" ]; then
  echo '{"loggedIn":true,"authMethod":"claude.ai"}'
  exit 0
fi
exit 9
`
	path := claudecode.RuntimePath(home)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

func shQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

func mustJSON(t testing.TB, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func writeJSON(t testing.TB, path string, v any) string {
	t.Helper()
	if err := os.WriteFile(path, []byte(mustJSON(t, v)), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

// realDir is a fresh directory whose path has no symlink component.
func realDir(t testing.TB) string {
	t.Helper()
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return dir
}

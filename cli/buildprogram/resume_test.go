package buildprogram

import (
	"os"
	"path/filepath"
)

func (e *env) state() map[string]string {
	e.t.Helper()
	idx, _ := os.ReadFile(filepath.Join(e.root, ".git/index"))
	app, _ := os.ReadFile(filepath.Join(e.root, "app.txt"))
	ap, _ := os.ReadFile(filepath.Join(e.root, ".kogen/local/approvals/fixture.json"))
	return map[string]string{"head": e.gitOutSafe("rev-parse", "HEAD"), "index": string(idx), "app": string(app), "approval": string(ap)}
}

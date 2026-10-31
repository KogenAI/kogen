package build

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"kogen/durable"
)

// Every Build runs hundreds of git commands, and on macOS /usr/bin/git is the xcode-select
// shim, which resolves the developer directory on each call and costs about twice what the
// real binary does. The suite looks the real one up once and puts a private directory holding
// only a git wrapper script first on PATH; the same git runs, only without the shim, and no other
// Xcode tool reaches PATH. The wrapper execs the real path rather than being a symlink to it:
// git reached through a symlink cannot compute its runtime prefix under the Command Line Tools
// and falls back to a compiled-in Xcode.app path, which breaks templates and info/exclude.
// Anywhere else, or when nothing is found, PATH is left alone.
func TestMain(m *testing.M) {
	var shim string
	if dir := realGitDir(); dir != "" {
		if d, err := os.MkdirTemp("", "kogen-git-"); err == nil {
			if writeGitWrapper(d, filepath.Join(dir, "git")) == nil {
				shim = d
				os.Setenv("PATH", d+string(os.PathListSeparator)+os.Getenv("PATH"))
			} else {
				os.RemoveAll(d)
			}
		}
	}
	durable.SkipSyncInTests()
	code := m.Run()
	if shim != "" {
		os.RemoveAll(shim)
	}
	os.Exit(code)
}

func writeGitWrapper(dir, git string) error {
	quoted := "'" + strings.ReplaceAll(git, "'", `'\''`) + "'"
	return os.WriteFile(filepath.Join(dir, "git"), []byte("#!/bin/sh\nexec "+quoted+" \"$@\"\n"), 0o700)
}

func realGitDir() string {
	if runtime.GOOS != "darwin" {
		return ""
	}
	if p, err := exec.LookPath("git"); err != nil || p != "/usr/bin/git" {
		return ""
	}
	out, err := exec.Command("xcode-select", "-p").Output()
	if err != nil {
		return ""
	}
	dir := filepath.Join(strings.TrimSpace(string(out)), "usr", "bin")
	if st, err := os.Stat(filepath.Join(dir, "git")); err != nil || st.IsDir() {
		return ""
	}
	return dir
}

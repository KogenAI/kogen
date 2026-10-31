package shape

import (
	"fmt"
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
	if err := resolveTestTools(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
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

// resolveTestTools exports one absolute Node as KOGEN_NODE (and the acceptance Cucumber as
// KOGEN_CUCUMBER) while HOME is still the developer's, before any fixture changes it.
func resolveTestTools() error {
	node := os.Getenv("KOGEN_NODE")
	if st, err := os.Stat(node); node == "" || err != nil || !st.Mode().IsRegular() || st.Mode().Perm()&0o111 == 0 {
		path, err := exec.LookPath("node")
		if err != nil {
			return fmt.Errorf("shape tests need Node: no executable node found (KOGEN_NODE unset or invalid, none on PATH)")
		}
		out, err := exec.Command(path, "-p", "process.execPath").Output()
		node = strings.TrimSpace(string(out))
		if err != nil || !filepath.IsAbs(node) {
			return fmt.Errorf("shape tests need Node: %s did not report its absolute path: %v", path, err)
		}
	}
	os.Setenv("KOGEN_NODE", node)
	if os.Getenv("KOGEN_CUCUMBER") == "" {
		if dir, err := filepath.Abs(filepath.Join("..", "..", "test", "acceptance", "node_modules")); err == nil {
			if st, err := os.Stat(dir); err == nil && st.IsDir() {
				os.Setenv("KOGEN_CUCUMBER", dir)
			}
		}
	}
	return nil
}

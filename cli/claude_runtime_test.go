package main

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/KogenAI/kogen-executor/executor/claudecode"
)

func saveClaudeToken(t *testing.T, home string) string {
	t.Helper()
	path := filepath.Join(home, ".kogen", "credentials", "claude-code.json")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(`{"provider":"claude-code","api_key":"sk-ant-oat01-SYNTHETIC"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func installRuntimeFile(t *testing.T, home string) string {
	t.Helper()
	path := claudecode.RuntimePath(home)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestProviderListRuntimeLine(t *testing.T) {
	const official = "Official compatibility (text/tool input, normal routes only):"
	list := func(home string) []string {
		t.Helper()
		t.Setenv("HOME", home)
		code, out := runCaptured(t, "provider", "list")
		if code != 0 {
			t.Fatalf("exit %d: %s", code, out)
		}
		return strings.Split(out, "\n")
	}
	runtimeLine := func(lines []string) int {
		for i, l := range lines {
			if strings.HasPrefix(l, "claude-code runtime:") {
				return i
			}
		}
		return -1
	}

	t.Run("neither a token nor the folder: no line", func(t *testing.T) {
		if lines := list(t.TempDir()); runtimeLine(lines) >= 0 {
			t.Fatalf("%q", lines)
		}
	})
	t.Run("a token and no runtime", func(t *testing.T) {
		home := t.TempDir()
		saveClaudeToken(t, home)
		lines := list(home)
		i := runtimeLine(lines)
		if i < 1 || lines[i-1] != "claude-code: token saved (not verified)" || lines[i] != "claude-code runtime: Claude Code 2.1.318 not installed" || lines[i+1] != official {
			t.Fatalf("%q", lines)
		}
	})
	t.Run("the folder without a runtime", func(t *testing.T) {
		home := t.TempDir()
		if err := os.MkdirAll(claudecode.Root(home), 0o700); err != nil {
			t.Fatal(err)
		}
		lines := list(home)
		if i := runtimeLine(lines); i < 0 || lines[i] != "claude-code runtime: Claude Code 2.1.318 not installed" || lines[i+1] != official {
			t.Fatalf("%q", lines)
		}
	})
	t.Run("an installed runtime", func(t *testing.T) {
		home := t.TempDir()
		path := installRuntimeFile(t, home)
		lines := list(home)
		if i := runtimeLine(lines); i < 0 || lines[i] != "claude-code runtime: Claude Code 2.1.318 installed ("+path+")" || lines[i+1] != official {
			t.Fatalf("%q", lines)
		}
	})
	t.Run("a directory in place of the executable is not installed", func(t *testing.T) {
		home := t.TempDir()
		if err := os.MkdirAll(claudecode.RuntimePath(home), 0o700); err != nil {
			t.Fatal(err)
		}
		lines := list(home)
		if i := runtimeLine(lines); i < 0 || lines[i] != "claude-code runtime: Claude Code 2.1.318 not installed" {
			t.Fatalf("%q", lines)
		}
	})
	t.Run("the JSON form is unchanged", func(t *testing.T) {
		home := t.TempDir()
		installRuntimeFile(t, home)
		t.Setenv("HOME", home)
		_, out := runCaptured(t, "provider", "list", "--json")
		if strings.Contains(out, "claude-code runtime") {
			t.Fatal(out)
		}
	})
}

// installation lays out <prefix>/lib/kogen/bin/kogen with its <prefix>/bin/kogen link.
func installation(t *testing.T) (root string) {
	t.Helper()
	prefix := t.TempDir()
	root = filepath.Join(prefix, "lib", "kogen")
	for _, dir := range []string{filepath.Join(root, "bin"), filepath.Join(prefix, "bin")} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(root, "bin", "kogen"), []byte("x"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(root, "bin", "kogen"), filepath.Join(prefix, "bin", "kogen")); err != nil {
		t.Fatal(err)
	}
	root, err := filepath.EvalSymlinks(root)
	if err != nil {
		t.Fatal(err)
	}
	return root
}

func uninstallCaptured(t *testing.T, root string) (string, error) {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout := os.Stdout
	os.Stdout = w
	runErr := uninstall(root)
	os.Stdout = stdout
	w.Close()
	out, _ := io.ReadAll(r)
	return string(out), runErr
}

func TestUninstallRemovesKogensClaudeRuntime(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	token := saveClaudeToken(t, home)
	installRuntimeFile(t, home)
	older := filepath.Join(claudecode.Root(home), "2.1.300", "claude")
	if err := os.MkdirAll(filepath.Dir(older), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(older, []byte("old"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(claudecode.ConfigDir(home), 0o700); err != nil {
		t.Fatal(err)
	}
	own := filepath.Join(home, ".claude", "settings.json")
	if err := os.MkdirAll(filepath.Dir(own), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(own, []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}
	out, err := uninstallCaptured(t, installation(t))
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(out, "\n")
	if len(lines) != 4 || !strings.HasPrefix(lines[0], "Uninstalled kogen from ") ||
		lines[1] != "Removed Kogen's Claude Code runtime from "+claudecode.Root(home) || !strings.HasPrefix(lines[2], "Kept your ") || lines[3] != "" {
		t.Fatalf("output %q", out)
	}
	if _, err := os.Lstat(claudecode.Root(home)); !os.IsNotExist(err) {
		t.Fatalf("runtime folder remains: %v", err)
	}
	for _, p := range []string{token, own} {
		if _, err := os.Stat(p); err != nil {
			t.Errorf("%s: %v", p, err)
		}
	}
}

func TestUninstallWithoutTheRuntimeFolderIsUnchanged(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	out, err := uninstallCaptured(t, installation(t))
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(out, "\n")
	if len(lines) != 3 || !strings.HasPrefix(lines[0], "Uninstalled kogen from ") || !strings.HasPrefix(lines[1], "Kept your ") || strings.Contains(out, "Removed") {
		t.Fatalf("output %q", out)
	}
}

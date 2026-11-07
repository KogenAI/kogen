package main

import (
	"bytes"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/KogenAI/kogen-loop/sys"
)

func TestInitReadinessNext(t *testing.T) {
	repo, home, install := t.TempDir(), t.TempDir(), t.TempDir()
	t.Setenv("HOME", home)
	git := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", args...)
		cmd.Dir = repo
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %s: %v", args, out, err)
		}
	}
	git("init", "-q")
	git("config", "user.name", "Fixture")
	git("config", "user.email", "fixture@example.invalid")
	write := func(base, path, content string, mode os.FileMode) {
		t.Helper()
		file := filepath.Join(base, path)
		if err := os.MkdirAll(filepath.Dir(file), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(file, []byte(content), mode); err != nil {
			t.Fatal(err)
		}
	}
	write(install, "lib/VERSION", "kogen fixture\n", 0600)
	write(install, "node-path", filepath.Join(install, "node"), 0600)
	write(install, "node", "#!/bin/sh\nexit 0\n", 0700)
	write(home, ".kogen/credentials/claude-code.json", `{"provider":"claude-code","api_key":"sk-ant-oat01-synthetic"}`, 0600)
	write(repo, ".kogen/models.yaml", "models:\n  shape: {executor: claude-code, model: claude-sonnet-5-5, effort: medium}\n  build: {executor: claude-code, model: claude-sonnet-5-5, effort: medium}\n  review: {executor: claude-code, model: claude-sonnet-5-5, effort: medium}\n", 0600)
	const acceptance = "  acceptance:\n    run: 'true'\n    steps_dir: features/steps\n"
	const checks = "  checks:\n    - {name: test, run: 'true'}\n"
	write(repo, "README.md", "fixture\n", 0600)
	git("add", "README.md")
	git("commit", "-qm", "baseline")
	write(repo, ".kogen/project.yaml", "version: 1\ncommands:\n"+checks+acceptance+"protect: []\n", 0600)
	wd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(repo); err != nil {
		t.Fatal(err)
	}
	defer os.Chdir(wd)
	for i := 0; i < 2; i++ {
		r, w, err := os.Pipe()
		if err != nil {
			t.Fatal(err)
		}
		old := os.Stdout
		os.Stdout = w
		code := run([]string{"init"}, func() (string, error) { return install, nil })
		os.Stdout = old
		w.Close()
		data, err := io.ReadAll(r)
		r.Close()
		if err != nil {
			t.Fatal(err)
		}
		const next = "Next: kogen intent shape <slug> <request-file>\n"
		if code != 0 || !strings.HasSuffix(string(data), next) || strings.Count(string(data), next) != 1 {
			t.Fatalf("init: exit %d:\n%s", code, data)
		}
	}
	for _, tc := range []struct {
		name, checks, acceptance string
		login                    bool
		want                     bool
	}{
		{"ready", checks, acceptance, true, true},
		{"missing acceptance", checks, "", true, false},
		{"missing checks", "  checks: []\n", acceptance, true, false},
		{"missing login", checks, acceptance, false, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if !tc.login {
				if err := os.Remove(filepath.Join(home, ".kogen/credentials/claude-code.json")); err != nil {
					t.Fatal(err)
				}
			}
			write(repo, ".kogen/project.yaml", "version: 1\ncommands:\n"+tc.checks+tc.acceptance+"protect: []\n", 0600)
			s := sys.NewWith(os.Environ(), repo)
			var out bytes.Buffer
			s.Stdout = &out
			printReadiness(s, install, repo)
			const next = "Next: kogen intent shape <slug> <request-file>\n"
			if got := strings.HasSuffix(out.String(), next); got != tc.want {
				t.Fatalf("next = %v, want %v:\n%s", got, tc.want, out.String())
			}
			if tc.want && strings.Count(out.String(), next) != 1 {
				t.Fatal(out.String())
			}
		})
	}
}

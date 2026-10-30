package git

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func mustPin(t *testing.T, r *Repo) *Pin {
	t.Helper()
	p, err := r.TakePin()
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func writeFile(t *testing.T, path, content string, perm os.FileMode) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), perm); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, perm); err != nil {
		t.Fatal(err)
	}
}

func wantChanges(t *testing.T, before *Pin, r *Repo, want ...string) {
	t.Helper()
	got := before.Changes(mustPin(t, r))
	if len(got) != len(want) {
		t.Fatalf("changes = %q, want %q", got, want)
	}
	for i := range want {
		if !strings.HasSuffix(got[i], want[i]) {
			t.Fatalf("changes = %q, want %q", got, want)
		}
	}
}

// TestPinHooksDirectory: every file of the effective hooks directory is pinned with its mode, bytes
// and, for a symlink, its text, resolved path and the resolved file's bytes; additions, removals and
// each kind of change are named by path, and an unchanged directory is no change.
func TestPinHooksDirectory(t *testing.T) {
	f := newFixture(t)
	target := filepath.Join(t.TempDir(), "target")
	writeFile(t, target, "#!/bin/sh\nexit 0\n", 0o755)
	writeFile(t, filepath.Join(f.Hooks, "commit-msg"), "#!/bin/sh\nexit 0\n", 0o755)
	writeFile(t, filepath.Join(f.Hooks, "notes.txt"), "not executable\n", 0o644)
	writeFile(t, filepath.Join(f.Hooks, "sub", "inner"), "x\n", 0o644)
	if err := os.Symlink(target, filepath.Join(f.Hooks, "pre-push")); err != nil {
		t.Fatal(err)
	}
	base := mustPin(t, f.Repo)
	wantChanges(t, base, f.Repo)

	cases := map[string]struct {
		mutate func()
		want   string
	}{
		"added hook":             {func() { writeFile(t, filepath.Join(f.Hooks, "pre-commit"), "x", 0o755) }, "pre-commit"},
		"added non-hook file":    {func() { writeFile(t, filepath.Join(f.Hooks, "README"), "x", 0o644) }, "README"},
		"removed hook":           {func() { os.Remove(filepath.Join(f.Hooks, "commit-msg")) }, "commit-msg"},
		"modified bytes":         {func() { writeFile(t, filepath.Join(f.Hooks, "commit-msg"), "#!/bin/sh\nexit 1\n", 0o755) }, "commit-msg"},
		"changed mode":           {func() { os.Chmod(filepath.Join(f.Hooks, "commit-msg"), 0o644) }, "commit-msg"},
		"modified plain file":    {func() { writeFile(t, filepath.Join(f.Hooks, "notes.txt"), "changed\n", 0o644) }, "notes.txt"},
		"nested file":            {func() { writeFile(t, filepath.Join(f.Hooks, "sub", "inner"), "y\n", 0o644) }, "inner"},
		"symlink target content": {func() { writeFile(t, target, "#!/bin/sh\nexit 2\n", 0o755) }, "pre-push"},
		"symlink target mode":    {func() { os.Chmod(target, 0o644) }, "pre-push"},
		"symlink retargeted": {func() {
			other := filepath.Join(t.TempDir(), "other")
			writeFile(t, other, "#!/bin/sh\nexit 0\n", 0o755)
			os.Remove(filepath.Join(f.Hooks, "pre-push"))
			os.Symlink(other, filepath.Join(f.Hooks, "pre-push"))
		}, "pre-push"},
		"regular file replaced by symlink": {func() {
			os.Remove(filepath.Join(f.Hooks, "commit-msg"))
			os.Symlink(target, filepath.Join(f.Hooks, "commit-msg"))
		}, "commit-msg"},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			// Each case starts from the baseline state.
			os.Remove(filepath.Join(f.Hooks, "commit-msg"))
			writeFile(t, target, "#!/bin/sh\nexit 0\n", 0o755)
			writeFile(t, filepath.Join(f.Hooks, "commit-msg"), "#!/bin/sh\nexit 0\n", 0o755)
			writeFile(t, filepath.Join(f.Hooks, "sub", "inner"), "x\n", 0o644)
			writeFile(t, filepath.Join(f.Hooks, "notes.txt"), "not executable\n", 0o644)
			os.Remove(filepath.Join(f.Hooks, "pre-push"))
			os.Remove(filepath.Join(f.Hooks, "pre-commit"))
			os.Remove(filepath.Join(f.Hooks, "README"))
			os.Symlink(target, filepath.Join(f.Hooks, "pre-push"))
			wantChanges(t, base, f.Repo)
			c.mutate()
			wantChanges(t, base, f.Repo, c.want)
		})
	}
}

// TestPinEffectiveHooksDirectory: the default, an absolute and a relative core.hooksPath select the
// directory that is pinned (a relative one against the work tree root, also from a linked worktree,
// whose default hooks are the common Git directory's), and a changed core.hooksPath is named.
func TestPinEffectiveHooksDirectory(t *testing.T) {
	f := newFixture(t)
	f.git(t, "config", "--unset-all", "core.hooksPath")
	writeFile(t, filepath.Join(f.Dir, ".git", "hooks", "commit-msg"), "default\n", 0o755)
	base := mustPin(t, f.Repo)

	t.Run("default", func(t *testing.T) {
		writeFile(t, filepath.Join(f.Dir, ".git", "hooks", "commit-msg"), "changed\n", 0o755)
		wantChanges(t, base, f.Repo, "commit-msg")
		writeFile(t, filepath.Join(f.Dir, ".git", "hooks", "commit-msg"), "default\n", 0o755)
	})
	t.Run("linked worktree shares the common hooks", func(t *testing.T) {
		wt := filepath.Join(t.TempDir(), "wt")
		f.git(t, "worktree", "add", "-q", wt, "-b", "linked")
		lr := New(wt, f.Env)
		lbase := mustPin(t, lr)
		writeFile(t, filepath.Join(f.Dir, ".git", "hooks", "pre-commit"), "x\n", 0o755)
		wantChanges(t, lbase, lr, "pre-commit")
		os.Remove(filepath.Join(f.Dir, ".git", "hooks", "pre-commit"))
	})
	t.Run("relative core.hooksPath is relative to the work tree root", func(t *testing.T) {
		f.configure(t, "core.hooksPath", "rel/hooks")
		defer f.git(t, "config", "--unset-all", "core.hooksPath")
		writeFile(t, filepath.Join(f.Dir, "rel", "hooks", "keep"), "x\n", 0o644)
		rel := mustPin(t, f.Repo)
		writeFile(t, filepath.Join(f.Dir, "rel", "hooks", "commit-msg"), "x\n", 0o755)
		wantChanges(t, rel, f.Repo, filepath.Join("rel", "hooks", "commit-msg"))
		// The default directory is no longer the one that counts.
		writeFile(t, filepath.Join(f.Dir, ".git", "hooks", "other"), "x\n", 0o755)
		defer os.Remove(filepath.Join(f.Dir, ".git", "hooks", "other"))
		wantChanges(t, mustPin(t, f.Repo), f.Repo)
		os.RemoveAll(filepath.Join(f.Dir, "rel"))
	})
	t.Run("absolute core.hooksPath and its change", func(t *testing.T) {
		abs := t.TempDir()
		writeFile(t, filepath.Join(abs, "commit-msg"), "x\n", 0o755)
		f.configure(t, "core.hooksPath", abs)
		defer f.git(t, "config", "--unset-all", "core.hooksPath")
		wantChanges(t, base, f.Repo, "core.hooksPath", "hooks directory "+abs)
		withAbs := mustPin(t, f.Repo)
		writeFile(t, filepath.Join(abs, "commit-msg"), "y\n", 0o755)
		wantChanges(t, withAbs, f.Repo, filepath.Join(abs, "commit-msg"))
	})
	t.Run("a missing hooks directory is pinned as absent", func(t *testing.T) {
		missing := filepath.Join(t.TempDir(), "none")
		f.configure(t, "core.hooksPath", missing)
		defer f.git(t, "config", "--unset-all", "core.hooksPath")
		p := mustPin(t, f.Repo)
		wantChanges(t, p, f.Repo)
		writeFile(t, filepath.Join(missing, "commit-msg"), "x\n", 0o755)
		wantChanges(t, p, f.Repo, filepath.Join(missing, "commit-msg"), "hooks directory "+missing)
	})
}

// TestPinExecutableConfiguration: every executable selector is compared by its effective values and
// order, a change is named by key and never shows a value, and other configuration is not part of it.
func TestPinExecutableConfiguration(t *testing.T) {
	f := newFixture(t)
	keys := []string{
		"core.fsmonitor", "core.sshCommand", "core.gitProxy", "core.editor", "sequence.editor", "core.pager",
		"pager.log", "credential.helper", "credential.https://example.invalid.helper", "gpg.program", "gpg.ssh.program",
		"gpg.x509.program", "filter.audit.clean", "filter.audit.smudge", "filter.audit.process", "diff.external",
		"diff.audit.command", "diff.audit.textconv", "merge.audit.driver", "interactive.diffFilter", "alias.audit",
	}
	secret := "s3cr3t-token-value"
	for _, key := range keys {
		t.Run(key, func(t *testing.T) {
			base := mustPin(t, f.Repo)
			f.configure(t, key, "true "+secret)
			defer f.git(t, "config", "--unset-all", key)
			got := base.Changes(mustPin(t, f.Repo))
			if len(got) != 1 || !strings.EqualFold(got[0], key) {
				t.Fatalf("changes = %q, want the key %s", got, key)
			}
			if strings.Contains(strings.Join(got, " "), secret) {
				t.Fatalf("a configuration value was named: %q", got)
			}
		})
	}
	t.Run("canonical spelling", func(t *testing.T) {
		base := mustPin(t, f.Repo)
		f.configure(t, "core.sshCommand", "ssh")
		defer f.git(t, "config", "--unset-all", "core.sshCommand")
		if got := base.Changes(mustPin(t, f.Repo)); len(got) != 1 || got[0] != "core.sshCommand" {
			t.Fatalf("changes = %q", got)
		}
	})
	t.Run("multivalue order and removal", func(t *testing.T) {
		f.git(t, "config", "--add", "credential.helper", "one")
		f.git(t, "config", "--add", "credential.helper", "two")
		base := mustPin(t, f.Repo)
		wantChanges(t, base, f.Repo)
		f.git(t, "config", "--unset-all", "credential.helper")
		f.git(t, "config", "--add", "credential.helper", "two")
		f.git(t, "config", "--add", "credential.helper", "one")
		wantChanges(t, base, f.Repo, "credential.helper")
		f.git(t, "config", "--unset-all", "credential.helper")
		wantChanges(t, base, f.Repo, "credential.helper")
	})
	t.Run("unrelated configuration is not pinned", func(t *testing.T) {
		base := mustPin(t, f.Repo)
		f.configure(t, "user.name", "Someone Else")
		f.configure(t, "core.ignorecase", "false")
		wantChanges(t, base, f.Repo)
	})
	t.Run("an included file and a conditional include", func(t *testing.T) {
		inc := filepath.Join(t.TempDir(), "inc.gitconfig")
		writeFile(t, inc, "[core]\n\teditor = one\n", 0o644)
		cond := filepath.Join(t.TempDir(), "cond.gitconfig")
		writeFile(t, cond, "[core]\n\tpager = one\n", 0o644)
		f.git(t, "config", "--add", "include.path", inc)
		f.git(t, "config", "--add", conditionalIncludeKey(t, f.Dir), cond)
		base := mustPin(t, f.Repo)
		writeFile(t, inc, "[core]\n\teditor = two\n", 0o644)
		wantChanges(t, base, f.Repo, "core.editor")
		writeFile(t, inc, "[core]\n\teditor = one\n", 0o644)
		writeFile(t, cond, "[core]\n\tpager = two\n", 0o644)
		wantChanges(t, base, f.Repo, "core.pager")
	})
}

// conditionalIncludeKey is the key of an includeIf that matches the Git directory of the repository
// at dir. Git matches a gitdir: pattern against the Git directory as given and with symlinks
// resolved, but never resolves symlinks in the pattern, so the pattern names the resolved directory.
func conditionalIncludeKey(t *testing.T, dir string) string {
	t.Helper()
	resolved, err := filepath.EvalSymlinks(dir)
	if err != nil {
		t.Fatal(err)
	}
	return "includeIf.gitdir:" + filepath.Join(resolved, ".git") + ".path"
}

// TestPinConditionalIncludeThroughSymlinkedCheckout: a pin of a checkout reached through a symlink
// still detects a change in a conditionally included file.
func TestPinConditionalIncludeThroughSymlinkedCheckout(t *testing.T) {
	real := t.TempDir()
	link := filepath.Join(t.TempDir(), "checkout")
	if err := os.Symlink(real, link); err != nil {
		t.Fatal(err)
	}
	env := testEnv()
	run(t, link, env, "init", "-q")
	cond := filepath.Join(t.TempDir(), "cond.gitconfig")
	writeFile(t, cond, "[core]\n\tpager = one\n", 0o644)
	run(t, link, env, "config", "--add", conditionalIncludeKey(t, link), cond)
	r := New(link, env)
	base := mustPin(t, r)
	writeFile(t, cond, "[core]\n\tpager = two\n", 0o644)
	wantChanges(t, base, r, "core.pager")
}

// TestPinReadsDefaultConfigurationLocations: when the environment hides the user's configuration,
// the files Git would read by default (here the home's .gitconfig and what it includes) are still
// pinned, because a later Git command of the user reads them.
func TestPinReadsDefaultConfigurationLocations(t *testing.T) {
	home := t.TempDir()
	inc := filepath.Join(home, "inc")
	writeFile(t, inc, "[core]\n\tsshCommand = one\n", 0o644)
	writeFile(t, filepath.Join(home, ".gitconfig"), "[include]\n\tpath = "+inc+"\n", 0o644)
	f := newFixture(t)
	r := New(f.Dir, append(testEnv(), "HOME="+home, "XDG_CONFIG_HOME="+filepath.Join(home, "xdg")))
	base := mustPin(t, r)
	wantChanges(t, base, r)
	writeFile(t, inc, "[core]\n\tsshCommand = two\n", 0o644)
	wantChanges(t, base, r, "core.sshCommand")
}

// TestPinRunsNothing: collecting and comparing a pin runs neither a hook nor the program a
// configuration selects.
func TestPinRunsNothing(t *testing.T) {
	f := newFixture(t)
	marker := filepath.Join(t.TempDir(), "ran")
	script := "#!/bin/sh\nprintf ran >> '" + marker + "'\nexit 0\n"
	for _, h := range []string{"commit-msg", "pre-commit", "fsmonitor-watchman", "post-index-change", "reference-transaction"} {
		writeFile(t, filepath.Join(f.Hooks, h), script, 0o755)
	}
	prog := filepath.Join(t.TempDir(), "prog")
	writeFile(t, prog, script, 0o755)
	base := mustPin(t, f.Repo)
	for _, kv := range [][2]string{
		{"core.fsmonitor", prog}, {"core.sshCommand", prog}, {"core.editor", prog}, {"core.pager", prog},
		{"filter.audit.clean", prog}, {"filter.audit.process", prog}, {"diff.external", prog}, {"alias.audit", "!" + prog},
		{"credential.helper", prog}, {"gpg.program", prog}, {"interactive.diffFilter", prog},
	} {
		f.configure(t, kv[0], kv[1])
	}
	if got := base.Changes(mustPin(t, f.Repo)); len(got) != 11 {
		t.Fatalf("changes = %q", got)
	}
	if _, err := os.Stat(marker); err == nil {
		t.Fatal("collecting or comparing the pin ran a hook or a configured program")
	}
}

// TestPinUnreadableIsAnError: state that cannot be read or resolved is never an unchanged pin.
func TestPinUnreadableIsAnError(t *testing.T) {
	t.Run("unreadable hook", func(t *testing.T) {
		if os.Geteuid() == 0 {
			t.Skip("permissions do not restrict root")
		}
		f := newFixture(t)
		path := filepath.Join(f.Hooks, "commit-msg")
		writeFile(t, path, "x\n", 0o755)
		os.Chmod(path, 0)
		defer os.Chmod(path, 0o755)
		if _, err := f.TakePin(); err == nil || !strings.Contains(err.Error(), "commit-msg") {
			t.Fatalf("error = %v", err)
		}
	})
	t.Run("unreadable configuration", func(t *testing.T) {
		f := newFixture(t)
		f.git(t, "config", "--add", "include.path", filepath.Join(f.Dir, ".git", "bad"))
		writeFile(t, filepath.Join(f.Dir, ".git", "bad"), "[core\n", 0o644)
		if _, err := f.TakePin(); err == nil {
			t.Fatal("a malformed included configuration was pinned")
		}
	})
	t.Run("not a repository", func(t *testing.T) {
		if _, err := New(t.TempDir(), testEnv()).TakePin(); err == nil {
			t.Fatal("a directory without a repository was pinned")
		}
	})
	t.Run("dangling hook symlink cannot be resolved", func(t *testing.T) {
		f := newFixture(t)
		link := filepath.Join(f.Hooks, "commit-msg")
		if err := os.Symlink(filepath.Join(t.TempDir(), "gone"), link); err != nil {
			t.Fatal(err)
		}
		if _, err := f.TakePin(); err == nil || !strings.Contains(err.Error(), "commit-msg") {
			t.Fatalf("error = %v", err)
		}
	})
	t.Run("dangling hooks directory cannot be resolved", func(t *testing.T) {
		f := newFixture(t)
		link := filepath.Join(t.TempDir(), "hooks")
		if err := os.Symlink(filepath.Join(t.TempDir(), "gone"), link); err != nil {
			t.Fatal(err)
		}
		f.configure(t, "core.hooksPath", link)
		if _, err := f.TakePin(); err == nil || !strings.Contains(err.Error(), link) {
			t.Fatalf("error = %v", err)
		}
	})
}

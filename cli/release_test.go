package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// These tests run the release-acceptance scripts of the repository (REL-3): test/suite.sh,
// test/live/self-build-check.sh and test/live/self-repo.sh.

func repoRoot(t *testing.T) string {
	t.Helper()
	root, err := filepath.Abs("..")
	if err != nil {
		t.Fatal(err)
	}
	return root
}

func readScript(t *testing.T, rel string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(repoRoot(t), rel))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func copyScript(t *testing.T, rel, dest string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dest, []byte(readScript(t, rel)), 0o755); err != nil {
		t.Fatal(err)
	}
}

// isolatedGit is an environment with no global or system Git configuration and no caller overrides.
func isolatedGit(home string, extra ...string) []string {
	var env []string
	for _, kv := range os.Environ() {
		if !strings.HasPrefix(kv, "GIT_") && !strings.HasPrefix(kv, "HOME=") {
			env = append(env, kv)
		}
	}
	env = append(env, "HOME="+home, "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1", "GIT_TERMINAL_PROMPT=0")
	return append(env, extra...)
}

func runIn(t *testing.T, dir string, env []string, name string, args ...string) (string, int) {
	t.Helper()
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	cmd.Env = env
	out, err := cmd.CombinedOutput()
	if err == nil {
		return string(out), 0
	}
	if ee, ok := err.(*exec.ExitError); ok {
		return string(out), ee.ExitCode()
	}
	t.Fatalf("%s %v: %v", name, args, err)
	return "", -1
}

// between is the text after the first `from` and before the first `to` that follows it.
func between(t *testing.T, text, from, to string) string {
	t.Helper()
	_, rest, ok := strings.Cut(text, from)
	if !ok {
		t.Fatalf("script has no %q", from)
	}
	part, _, ok := strings.Cut(rest, to)
	if !ok {
		t.Fatalf("script has no %q after %q", to, from)
	}
	return part
}

func TestSelfBuildGateRunsTheMaintainedSuiteAndPropagatesItsFailure(t *testing.T) {
	// ExUnit: test/integration/contract_regressions_test.exs: REL-3 self-build gate runs the maintained suite and propagates its failure
	work := t.TempDir()
	project := filepath.Join(t.TempDir(), "project")
	copyScript(t, "test/suite.sh", filepath.Join(project, "test/suite.sh"))

	// The real suite must reject this candidate before reaching any layer: the archive the
	// gate hands it does not exist.
	gate := between(t, readScript(t, "test/live/self-build-check.sh"), `say "packaged $archive"`, `mkdir -p "$work/extract"`)
	script := filepath.Join(work, "suite-gate.sh")
	prelude := "set -eu\nwork=\"$1\"\narchive=missing-archive.tar.gz\nsay() { printf '%s\\n' \"$*\"; }\n"
	if err := os.WriteFile(script, []byte(prelude+gate), 0o644); err != nil {
		t.Fatal(err)
	}
	goBin, err := exec.LookPath("go")
	if err != nil {
		t.Skip("go is not on PATH")
	}
	env := isolatedGit(t.TempDir(), "PATH="+filepath.Dir(goBin)+":"+os.Getenv("PATH"),
		"GOMODCACHE="+goEnv(t, goBin, "GOMODCACHE"), "GOCACHE="+goEnv(t, goBin, "GOCACHE"))
	out, code := runIn(t, project, env, "/bin/sh", script, work)
	if code != 1 {
		t.Fatalf("exit %d, want 1\n%s", code, out)
	}
	for _, want := range []string{"suite: archive not found: missing-archive.tar.gz", "FAIL: the self-built deterministic suite"} {
		if !strings.Contains(out, want) {
			t.Fatalf("output lacks %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, "ok: the self-built deterministic suite passes") {
		t.Fatalf("a failing suite was reported as passing:\n%s", out)
	}
}

func goEnv(t *testing.T, goBin, name string) string {
	t.Helper()
	out, err := exec.Command(goBin, "env", name).Output()
	if err != nil {
		t.Fatal(err)
	}
	return strings.TrimSpace(string(out))
}

// observation is the part of the self-build check that runs the installed Kogen outside the
// checkout and judges what it prints.
func observation(t *testing.T, work string) string {
	t.Helper()
	_, observe, ok := strings.Cut(readScript(t, "test/live/self-build-check.sh"), "\nset +e\n")
	if !ok {
		t.Fatal("script has no observation")
	}
	script := filepath.Join(work, "observe.sh")
	prelude := "set -eu\nwork=\"$1\"\nsay() { printf '%s\\n' \"$*\"; }\nset +e\n"
	if err := os.WriteFile(script, []byte(prelude+observe), 0o644); err != nil {
		t.Fatal(err)
	}
	return script
}

func unreadableLogin(t *testing.T, work string) {
	t.Helper()
	dir := filepath.Join(work, "home/.kogen/credentials")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "chatgpt.json"), []byte("not json\n"), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestObservationRejectsAnInstalledReleaseWithoutItsProgram(t *testing.T) {
	// ExUnit: test/integration/contract_regressions_test.exs: REL-3 observation rejects an installed release whose core is unavailable
	// Kogen is one program now, so the guarantee is that a release whose installed program is
	// missing or cannot run is never reported as observing the change.
	for name, install := range map[string]func(prefix string){
		"no program installed": func(prefix string) { os.MkdirAll(filepath.Join(prefix, "bin"), 0o755) },
		"a program that cannot run": func(prefix string) {
			os.MkdirAll(filepath.Join(prefix, "bin"), 0o755)
			os.WriteFile(filepath.Join(prefix, "bin/kogen"), []byte("#!/nonexistent/interpreter\n"), 0o755)
		},
	} {
		t.Run(name, func(t *testing.T) {
			work := t.TempDir()
			install(filepath.Join(work, "prefix"))
			unreadableLogin(t, work)
			out, code := runIn(t, work, isolatedGit(t.TempDir()), "/bin/sh", observation(t, work), work)
			if code != 1 {
				t.Fatalf("exit %d, want 1\n%s", code, out)
			}
			if !strings.Contains(out, "FAIL: expected provider/login exit 4") {
				t.Fatalf("the observation was not refused for its exit code:\n%s", out)
			}
			if strings.Contains(out, "ok: the change is observed") {
				t.Fatalf("an unusable release was reported as observing the change:\n%s", out)
			}
		})
	}
}

func TestDisposableSelfRepositoriesLeaveSourceHeadIndexAndEditsUntouched(t *testing.T) {
	// ExUnit: test/integration/contract_regressions_test.exs: REL-3 disposable self repositories leave source HEAD, index and edits untouched
	if _, err := exec.LookPath("rsync"); err != nil {
		t.Skip("rsync is not available")
	}
	home := t.TempDir()
	root := t.TempDir()
	repo := filepath.Join(root, "repo")
	env := isolatedGit(home)
	git := func(dir string, args ...string) string {
		t.Helper()
		out, code := runIn(t, dir, env, "git", args...)
		if code != 0 {
			t.Fatalf("git %v: %d\n%s", args, code, out)
		}
		return out
	}
	write := func(path, content string) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.MkdirAll(repo, 0o755); err != nil {
		t.Fatal(err)
	}
	git(repo, "init", "-q", "--initial-branch=main")
	for k, v := range map[string]string{"user.name": "Fixture", "user.email": "fixture@example.invalid", "commit.gpgsign": "false", "core.hooksPath": t.TempDir()} {
		git(repo, "config", k, v)
	}
	write(filepath.Join(repo, "README.md"), "# Fixture project\n")
	write(filepath.Join(repo, "app.txt"), "baseline\n")
	copyScript(t, "test/live/self-repo.sh", filepath.Join(repo, "test/live/self-repo.sh"))
	git(repo, "add", "-A")
	git(repo, "commit", "-qm", "Add self repository setup")
	worktree := filepath.Join(root, "worktree")
	git(repo, "worktree", "add", "-qb", "candidate", worktree)

	author := []string{"GIT_AUTHOR_NAME=Fixture", "GIT_AUTHOR_EMAIL=fixture@example.invalid", "GIT_COMMITTER_NAME=Fixture", "GIT_COMMITTER_EMAIL=fixture@example.invalid"}
	for i, source := range []string{repo, worktree} {
		write(filepath.Join(source, "app.txt"), "staged candidate\n")
		git(source, "add", "app.txt")
		write(filepath.Join(source, "README.md"), "Uncommitted candidate\n")
		head, index, status := git(source, "rev-parse", "HEAD"), git(source, "write-tree"), git(source, "status", "--porcelain")
		destination := filepath.Join(root, "disposable-"+string(rune('0'+i)))

		out, code := runIn(t, source, isolatedGit(home, author...), "/bin/sh", filepath.Join(source, "test/live/self-repo.sh"), destination)
		if code != 0 {
			t.Fatalf("self-repo.sh in %s: %d\n%s", source, code, out)
		}
		if st, err := os.Stat(filepath.Join(destination, ".git")); err != nil || !st.IsDir() {
			t.Fatalf("the disposable repository has no .git folder: %v", err)
		}
		if got := git(source, "rev-parse", "HEAD"); got != head {
			t.Fatalf("source HEAD moved: %s -> %s", head, got)
		}
		if got := git(source, "write-tree"); got != index {
			t.Fatalf("source index changed: %s -> %s", index, got)
		}
		if got := git(source, "status", "--porcelain"); got != status {
			t.Fatalf("source status changed: %q -> %q", status, got)
		}
		for path, want := range map[string]string{"README.md": "Uncommitted candidate\n", "app.txt": "staged candidate\n"} {
			b, err := os.ReadFile(filepath.Join(destination, path))
			if err != nil || string(b) != want {
				t.Fatalf("%s in the disposable repository = %q, %v", path, b, err)
			}
		}
		if got := git(destination, "status", "--porcelain"); got != "" {
			t.Fatalf("the disposable repository is not clean: %q", got)
		}
		if got := git(destination, "show", "HEAD:README.md"); got != "Uncommitted candidate\n" {
			t.Fatalf("committed README = %q", got)
		}
	}
}

// suiteWithFakeGo copies test/suite.sh into a scratch project whose spec, live-helper and
// acceptance layers are fakes and whose `go` records its arguments and working directory, then
// runs the suite. It never runs the real go test, Cucumber or Quint.
func suiteWithFakeGo(t *testing.T, goExit int) (out string, code int, calls string, project string) {
	t.Helper()
	base := t.TempDir()
	project = filepath.Join(base, "project")
	bin := filepath.Join(base, "bin")
	record := filepath.Join(base, "go-calls.txt")
	put := func(path, text string, mode os.FileMode) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(text), mode); err != nil {
			t.Fatal(err)
		}
	}
	copyScript(t, "test/suite.sh", filepath.Join(project, "test/suite.sh"))
	put(filepath.Join(project, "archive.tar.gz"), "archive\n", 0o644)
	for dir, tool := range map[string]string{"spec": "quint", "test/acceptance": "cucumber-js"} {
		d := filepath.Join(project, dir)
		put(filepath.Join(d, "package.json"), "{}\n", 0o644)
		put(filepath.Join(d, "package-lock.json"), "{}\n", 0o644)
		put(filepath.Join(d, "node_modules/.bin", tool), "#!/bin/sh\nexit 0\n", 0o755)
		sum, code := runIn(t, d, os.Environ(), "shasum", "-a", "256", "package.json", "package-lock.json")
		if code != 0 {
			t.Fatalf("shasum: %d\n%s", code, sum)
		}
		put(filepath.Join(d, "node_modules/.kogen-suite-manifests"), strings.TrimRight(sum, "\n")+"\n", 0o644)
	}
	put(filepath.Join(project, "spec/check.sh"), "exit 0\n", 0o644)
	put(filepath.Join(project, "test/live/check-verify.sh"), "exit 0\n", 0o644)
	put(filepath.Join(project, "test/live/check-journey.sh"), "exit 0\n", 0o644)
	put(filepath.Join(project, "cli/.keep"), "", 0o644)
	put(filepath.Join(bin, "npm"), "#!/bin/sh\nexit 0\n", 0o755)
	put(filepath.Join(bin, "go"), "#!/bin/sh\n{ echo call; echo \"cwd:$(pwd -P)\"; for a in \"$@\"; do printf 'arg:%s\\n' \"$a\"; done; } >> \""+record+"\"\nexit "+strconv.Itoa(goExit)+"\n", 0o755)

	nodeBin, err := exec.LookPath("node")
	if err != nil {
		t.Skip("node is not on PATH")
	}
	env := isolatedGit(t.TempDir(),
		"KOGEN_ARCHIVE="+filepath.Join(project, "archive.tar.gz"),
		"PATH="+strings.Join([]string{bin, filepath.Dir(nodeBin), "/usr/bin", "/bin", "/usr/sbin", "/sbin"}, ":"))
	out, code = runIn(t, base, env, "/bin/sh", filepath.Join(project, "test/suite.sh"))
	if b, err := os.ReadFile(record); err == nil {
		calls = string(b)
	}
	project, _ = filepath.EvalSymlinks(project)
	return out, code, calls, project
}

func TestSuiteGoLayerPassesAnExplicitLimitOf40MinutesInTheCliDirectory(t *testing.T) {
	out, code, calls, project := suiteWithFakeGo(t, 0)
	if code != 0 {
		t.Fatalf("exit %d, want 0\n%s", code, out)
	}
	want := "call\ncwd:" + filepath.Join(project, "cli") + "\narg:test\narg:-race\narg:-count=1\narg:-timeout=40m\narg:./...\n"
	if calls != want {
		t.Fatalf("go was called as\n%s\nwant exactly once as\n%s\n%s", calls, want, out)
	}
}

func TestSuiteFailsWhenTheGoLayerExitsNonzero(t *testing.T) {
	out, code, calls, _ := suiteWithFakeGo(t, 1)
	if code != 1 {
		t.Fatalf("exit %d, want 1\n%s", code, out)
	}
	if strings.Count(calls, "call\n") != 1 {
		t.Fatalf("go was not called exactly once:\n%s", calls)
	}
	var failed bool
	for _, line := range strings.Split(out, "\n") {
		failed = failed || strings.HasPrefix(line, "suite: go FAILED")
		if strings.HasPrefix(line, "suite: all passed") {
			t.Fatalf("a failing go layer was reported as passing:\n%s", out)
		}
	}
	if !failed {
		t.Fatalf("output has no line starting with %q:\n%s", "suite: go FAILED", out)
	}
}

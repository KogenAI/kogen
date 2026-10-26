package agent

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"kogen-loop/tools"
	"kogen/git"
)

// gitIn runs git in dir and fails the test when it fails.
func gitIn(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"}, args...)...)
	cmd.Dir = dir
	cmd.Env = hermeticEnv()
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return string(out)
}

func adapterRepo(t *testing.T) (string, *git.Repo) {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	gitIn(t, root, "init", "-q")
	return root, git.New(root, hermeticEnv())
}

func TestGitOfNoRepositoryIsNoGit(t *testing.T) {
	if g := Git(nil); g != nil {
		t.Errorf("Git(nil) = %v: tools would call through a nil repository instead of using its own runner", g)
	}
}

func TestGitAdapterRunsAndConvertsKogensResults(t *testing.T) {
	root, repo := adapterRepo(t)
	os.WriteFile(filepath.Join(root, "a.txt"), []byte("one\n"), 0o644)
	g := Git(repo)
	res, err := g.Run("ls-files", "--others", "--exclude-standard")
	if err != nil {
		t.Fatal(err)
	}
	want, err := repo.Run("ls-files", "--others", "--exclude-standard")
	if err != nil {
		t.Fatal(err)
	}
	if res != (tools.GitResult{Stdout: want.Stdout, Stderr: want.Stderr, Status: want.Status}) || res.Stdout != "a.txt\n" || res.Status != 0 {
		t.Errorf("Run = %+v, Kogen's = %+v", res, want)
	}
	// A command that ran and failed is a status, with Git's own text.
	res, err = g.Run("grep", "-e", "never-there", "--", "a.txt")
	if err != nil || res.Status != 1 {
		t.Errorf("no match: %+v %v", res, err)
	}
	res, err = g.Run("rev-parse", "--verify", "no-such-ref")
	if err != nil || res.Status == 0 || res.Stderr == "" {
		t.Errorf("failure: %+v %v", res, err)
	}
	// Kogen's own guard still applies: the adapter is the repository, not a new runner.
	if _, err := g.Run("push"); err == nil {
		t.Error("the forbidden-subcommand guard was bypassed")
	}
}

func TestGitAdapterHeadAndTreeAreTheRepositorys(t *testing.T) {
	root, repo := adapterRepo(t)
	g := Git(repo)
	if g.Head() != "" {
		t.Errorf("Head of an empty repository = %q", g.Head())
	}
	os.WriteFile(filepath.Join(root, "a.txt"), []byte("one\n"), 0o644)
	gitIn(t, root, "add", "-A")
	gitIn(t, root, "commit", "-q", "-m", "init")
	if g.Head() != repo.Head() || g.Head() != strings.TrimSpace(gitIn(t, root, "rev-parse", "HEAD")) {
		t.Errorf("Head = %q, repo %q", g.Head(), repo.Head())
	}
	os.MkdirAll(filepath.Join(root, "skip"), 0o755)
	os.WriteFile(filepath.Join(root, "skip", "x"), []byte("x\n"), 0o644)
	os.WriteFile(filepath.Join(root, "b.txt"), []byte("two\n"), 0o644)
	got, err := g.Tree(g.Head(), []string{"skip"})
	if err != nil {
		t.Fatal(err)
	}
	want, err := repo.Tree(repo.Head(), []string{"skip"})
	if err != nil || got != want {
		t.Errorf("Tree = %q, repo's %q, %v", got, want, err)
	}
	if _, err := g.Tree("", nil); err == nil {
		t.Error("an empty start was accepted")
	}
}

func TestToolsRunThroughKogensRepository(t *testing.T) {
	root, repo := adapterRepo(t)
	os.WriteFile(filepath.Join(root, "a.txt"), []byte("needle\n"), 0o644)
	tl := newTools(root, tools.ListFilesTool, tools.SearchTextTool)
	tl.Repo = Git(repo)
	if got := run(t, tl, tools.ListFilesTool, nil); got != "a.txt" {
		t.Errorf("list_files: %q", got)
	}
	if got := run(t, tl, tools.SearchTextTool, map[string]any{"pattern": "needle"}); got != "a.txt:1:needle" {
		t.Errorf("search_text: %q", got)
	}
	if got := run(t, tl, tools.SearchTextTool, map[string]any{"pattern": "absent"}); got != "(no matches)" {
		t.Errorf("search_text: %q", got)
	}
}

package build

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"kogen-loop/sys"
	"kogen/project"
	"kogen/testproc"
	"kogen/verify"
)

func TestBaselineCacheTreeAndCustody(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	cmd := exec.Command("git", "init", "-q", root)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git init: %v: %s", err, out)
	}
	checks := []project.Check{{Name: "closed", Run: ":"}}
	first, dir, err := baselineIdentity(root, checks)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := readBaselineEvidence(dir, first, 0, "closed"); ok {
		t.Fatal("unexpected entry")
	}
	status, position, output := 0, 0, ""
	publishBaselineEvidence(dir, baselineEvidence{Version: 2, Complete: true, Command: ":", Status: &status, Output: &output, Position: &position, Identity: first, Name: "closed", Reference: "run/log.jsonl"})
	if _, ok := readBaselineEvidence(dir, first, 0, "closed"); !ok {
		t.Fatal("missing completed evidence")
	}
	if err := os.WriteFile(filepath.Join(root, "ignored"), []byte("a"), 0600); err != nil {
		t.Fatal(err)
	}
	second, _, err := baselineIdentity(root, checks)
	if err != nil {
		t.Fatal(err)
	}
	if first == second {
		t.Fatal("tree change did not invalidate")
	}
	if _, ok := readBaselineEvidence(dir, second, 0, "closed"); ok {
		t.Fatal("reused different tree")
	}
	if err := os.WriteFile(baselineCachePath(dir, first, 0), []byte(`{"version":1`), 0600); err != nil {
		t.Fatal(err)
	}
	if _, ok := readBaselineEvidence(dir, first, 0, "closed"); ok {
		t.Fatal("accepted partial evidence")
	}
	// A syntactically valid record missing the completion fields is also a miss.
	incomplete := fmt.Sprintf(`{"version":2,"identity":%q,"index":0,"name":"closed","reference":"run/log.jsonl"}`, first)
	if err := os.WriteFile(baselineCachePath(dir, first, 0), []byte(incomplete), 0600); err != nil {
		t.Fatal(err)
	}
	if _, ok := readBaselineEvidence(dir, first, 0, "closed"); ok {
		t.Fatal("accepted incomplete evidence")
	}

}

func TestBaselinePerBaseEligibility(t *testing.T) {
	t.Parallel()
	commands := []string{":", " :", ": ", "true", "sh -c :", ":; :", "date >/dev/null", "test -e /dev/null"}
	checks := make([]project.Check, len(commands))
	for i, c := range commands {
		checks[i] = project.Check{Name: fmt.Sprintf("check-%d", i), Run: c}
	}
	e := newEnv(t, func(c *project.Config) { c.Checks = checks })
	session, _, _ := e.session()
	run, err := StartRun(e.root)
	if err != nil {
		t.Fatal(err)
	}
	a := &Attempt{State: State{Root: e.root, Config: &project.Config{Checks: checks}, Run: run}, s: session}
	for i := 0; i < 2; i++ {
		if err := a.recordBaseline(context.Background()); err != nil {
			t.Fatal(err)
		}
		for _, result := range a.CheckBaseline {
			if result.Status != 0 || result.Output != "" {
				t.Fatalf("unexpected result: %+v", result)
			}
		}
	}
	evs := e.events(run.ID)
	for i := range checks {
		count := len(commandResults(evs, checks[i].Name))
		want := 2
		if i == 0 {
			want = 1
		}
		if count != want {
			t.Errorf("%q actual evaluations %d, want %d", commands[i], count, want)
		}
	}
	hits := eventsNamed(evs, "baseline_reuse")
	if len(hits) != 1 || hits[0]["name"] != checks[0].Name {
		t.Fatalf("reuse events: %v", hits)
	}
}

func TestBaselinePerBaseIdentity(t *testing.T) {
	if !testproc.Isolate(t) {
		return
	}
	if child := os.Getenv("BASELINE_ID_CHILD"); child != "" {
		id, _, err := baselineIdentity(child, []project.Check{{Name: "executable", Run: ":"}})
		if err != nil {
			t.Fatal(err)
		}
		fmt.Println("CHILD_ID=" + id)
		return
	}
	root := t.TempDir()
	git := func(dir string, args ...string) {
		t.Helper()
		c := exec.Command("git", args...)
		c.Dir = dir
		c.Env = append(os.Environ(), "GIT_AUTHOR_NAME=test", "GIT_AUTHOR_EMAIL=test@example.invalid", "GIT_COMMITTER_NAME=test", "GIT_COMMITTER_EMAIL=test@example.invalid")
		if out, err := c.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v: %s", args, err, out)
		}
	}
	git(root, "init", "-q")
	write := func(path, value string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(root, path), []byte(value), 0644); err != nil {
			t.Fatal(err)
		}
	}
	write("tracked", "a")
	write(".gitignore", "ignored\n")
	if err := os.Symlink("tracked", filepath.Join(root, "link")); err != nil {
		t.Fatal(err)
	}
	git(root, "add", ".")
	git(root, "commit", "-qm", "base")
	other := filepath.Join(t.TempDir(), "worktree")
	git(root, "worktree", "add", "-q", "--detach", other, "HEAD")
	checks := []project.Check{{Name: "a", Run: ":"}, {Name: "b", Run: "true"}}
	identity := func(path string, cs []project.Check) string {
		t.Helper()
		id, _, err := baselineIdentity(path, cs)
		if err != nil {
			t.Fatal(err)
		}
		return id
	}
	base := identity(root, checks)
	if got := identity(other, checks); got != base {
		t.Fatalf("worktree identity differs: %s %s", base, got)
	}
	changed := func() {
		t.Helper()
		if identity(root, checks) == base {
			t.Fatal("changed input retained identity")
		}
	}
	write("tracked", "b")
	changed()
	write("tracked", "a")
	write("untracked", "a")
	changed()
	if err := os.Remove(filepath.Join(root, "untracked")); err != nil {
		t.Fatal(err)
	}
	write("ignored", "a")
	changed()
	if err := os.Remove(filepath.Join(root, "ignored")); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(filepath.Join(root, "tracked"), 0755); err != nil {
		t.Fatal(err)
	}
	changed()
	if err := os.Chmod(filepath.Join(root, "tracked"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(root, "link")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(".gitignore", filepath.Join(root, "link")); err != nil {
		t.Fatal(err)
	}
	changed()
	if err := os.Remove(filepath.Join(root, "link")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("tracked", filepath.Join(root, "link")); err != nil {
		t.Fatal(err)
	}
	if identity(root, checks) != base {
		t.Fatal("restored tree did not regain identity")
	}
	modified := []project.Check{{Name: "a", Run: ": "}, {Name: "b", Run: "true"}}
	if identity(root, modified) == base {
		t.Fatal("command bytes ignored")
	}
	t.Setenv("KOGEN_BASELINE_IDENTITY_TEST", "changed")
	changed()
	t.Setenv("KOGEN_BASELINE_IDENTITY_TEST", "")
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	binary, err := os.ReadFile(exe)
	if err != nil {
		t.Fatal(err)
	}
	childPath := filepath.Join(t.TempDir(), "identity-test")
	runChild := func(bytes []byte) string {
		t.Helper()
		if err := os.WriteFile(childPath, bytes, 0755); err != nil {
			t.Fatal(err)
		}
		cmd := exec.Command(childPath, "-test.run=^TestBaselinePerBaseIdentity$", "-test.v")
		cmd.Env = append(os.Environ(), "BASELINE_ID_CHILD="+root)
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("identity child: %v: %s", err, out)
		}
		for _, line := range strings.Split(string(out), "\n") {
			if strings.HasPrefix(line, "CHILD_ID=") {
				return line
			}
		}
		t.Fatalf("missing child identity: %s", out)
		return ""
	}
	one := runChild(binary)
	two := runChild(append(append([]byte(nil), binary...), 0))
	if one == two {
		t.Fatal("executable bytes ignored")
	}

}

// Baseline and comparison retain actual successful output as well as failures.
func TestBaselineComparisonPassingOutput(t *testing.T) {
	t.Parallel()
	got := stateOf(verify.CommandResult{Name: "check", Command: "printf hello", Status: 0, Output: "hello"})
	if got.State != checkPassed || got.Status == nil || *got.Status != 0 || got.Output != "hello" {
		t.Fatalf("comparison lost actual result: %+v", got)
	}
}

func TestBaselinePerBaseFailures(t *testing.T) {
	t.Parallel()
	checks := []project.Check{{Name: "closed", Run: ":"}, {Name: "failure", Run: `printf 'failure-marker\n'; exit 7`}}
	e := newEnv(t, func(c *project.Config) { c.Checks = checks })
	f := e.prov
	f.then(refused())
	first := e.reviewed()
	if first.exit == 0 {
		t.Fatal("provider refusal unexpectedly landed")
	}
	ids := e.runIDs()
	if len(ids) != 1 {
		t.Fatalf("runs: %v", ids)
	}
	firstID := ids[0]
	f.then(f.calls("write_file", map[string]any{"path": "app.txt", "content": "candidate\n"}, "finish", map[string]any{"summary": "candidate"}), refused())
	start := e.head()
	second := e.reviewed()
	if second.exit == 0 || e.head() != start {
		t.Fatalf("failed final check landed: %s", second.shown())
	}
	var secondID string
	for _, id := range e.runIDs() {
		if id != firstID {
			secondID = id
		}
	}
	if secondID == "" {
		t.Fatal("missing second run")
	}
	for _, id := range []string{firstID, secondID} {
		rows := checkRows(t, e.result(id))
		if len(rows) != 2 || rows[0]["name"] != "closed" || rows[1]["name"] != "failure" || rows[1]["command"] != checks[1].Run {
			t.Fatalf("baseline order/commands: %v", rows)
		}
		expectSide(t, rows[0], "before", "passed", 0, "")
		expectSide(t, rows[1], "before", "failed", 7, "failure-marker")
		if len(commandResults(e.events(id), "failure")) == 0 {
			t.Fatal("shell failure did not execute")
		}
	}
	events := e.events(secondID)
	hits := eventsNamed(events, "baseline_reuse")
	if len(hits) != 1 || hits[0]["name"] != "closed" {
		t.Fatalf("unexpected reuse: %v", hits)
	}
	if got := commandResults(events, "failure"); len(got) < 2 || got[0] != 7 || got[1] != 7 {
		t.Fatalf("final failure did not run fresh: %v", got)
	}
	if len(f.reviewRequests()) != 0 {
		t.Fatal("review ran after red final check")
	}
	green := newEnv(t, func(c *project.Config) { c.Checks = []project.Check{{Name: "closed", Run: ":"}} })
	green.prov.then(refused())
	if result := green.reviewed(); result.exit == 0 {
		t.Fatal("first build unexpectedly landed")
	}
	firstGreenID := green.onlyRun()
	green.prov.then(landScript(green.prov)...)
	green.prov.then(submit(green.prov, "approve"))
	if result := green.reviewed(); result.exit != 0 {
		t.Fatalf("green build: %s", result.shown())
	}
	var greenID string
	for _, id := range green.runIDs() {
		if id != firstGreenID {
			greenID = id
		}
	}
	evs := green.events(greenID)
	if len(eventsNamed(evs, "baseline_reuse")) != 1 || len(eventsNamed(evs, "pass")) == 0 || len(green.prov.reviewRequests()) != 1 {
		t.Fatalf("green gate or review missing: %v", evs)
	}
	rows := checkRows(t, green.result(greenID))
	expectSide(t, rows[0], "after", "passed", 0, "")
}

func TestBaselinePerBaseCustody(t *testing.T) {
	t.Parallel()
	if os.Getenv("BASELINE_CUSTODY_CHILD") == "1" {
		root, err := os.Getwd()
		if err != nil {
			t.Fatal(err)
		}
		run, err := StartRun(root)
		if err != nil {
			t.Fatal(err)
		}
		checks := []project.Check{{Name: "closed", Run: ":"}}
		a := &Attempt{State: State{Root: root, Config: &project.Config{Checks: checks}, Run: run}, s: sys.NewWith(os.Environ(), root)}
		if err := a.recordBaseline(context.Background()); err != nil {
			t.Fatal(err)
		}
		raw, err := os.ReadFile(run.LogPath)
		if err != nil {
			t.Fatal(err)
		}
		fmt.Printf("CHILD_EVENTS=%s\n", strings.ReplaceAll(string(raw), "\n", "|"))
		return
	}
	root := t.TempDir()
	git := func(dir string, args ...string) {
		t.Helper()
		c := exec.Command("git", args...)
		c.Dir = dir
		c.Env = append(os.Environ(), "GIT_AUTHOR_NAME=test", "GIT_AUTHOR_EMAIL=test@example.invalid", "GIT_COMMITTER_NAME=test", "GIT_COMMITTER_EMAIL=test@example.invalid")
		if out, err := c.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v %s", args, err, out)
		}
	}
	git(root, "init", "-q")
	if err := os.Mkdir(filepath.Join(root, ".kogen"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, ".kogen", "keep"), []byte("x"), 0644); err != nil {
		t.Fatal(err)
	}
	git(root, "add", ".")
	git(root, "commit", "-qm", "base")
	other := filepath.Join(t.TempDir(), "worktree")
	git(root, "worktree", "add", "-q", "--detach", other, "HEAD")
	child := func(dir string) string {
		t.Helper()
		exe, err := os.Executable()
		if err != nil {
			t.Fatal(err)
		}
		cmd := exec.Command(exe, "-test.run=^TestBaselinePerBaseCustody$", "-test.v")
		cmd.Dir = dir
		cmd.Env = append(os.Environ(), "BASELINE_CUSTODY_CHILD=1", "BASELINE_CUSTODY_SECRET=private-custody-secret-724")
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("child: %v: %s", err, out)
		}
		return string(out)
	}
	first := child(root)
	if !strings.Contains(first, `"event":"command_result"`) || strings.Contains(first, `"event":"baseline_reuse"`) {
		t.Fatalf("first events %s", first)
	}
	second := child(other)
	if !strings.Contains(second, `"event":"baseline_reuse"`) || strings.Contains(second, `"event":"command_result"`) {
		t.Fatalf("second events %s", second)
	}
	common := filepath.Join(root, ".git", "kogen-baselines")
	files, err := os.ReadDir(common)
	if err != nil || len(files) != 1 {
		t.Fatalf("cache entries %v: %v", files, err)
	}
	cache := filepath.Join(common, files[0].Name())
	raw, err := os.ReadFile(cache)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), "private-custody-secret-724") {
		t.Fatal("persisted secret")
	}
	independent := t.TempDir()
	git(independent, "init", "-q")
	if err := os.Mkdir(filepath.Join(independent, ".kogen"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(independent, ".kogen", "keep"), []byte("x"), 0644); err != nil {
		t.Fatal(err)
	}
	git(independent, "add", ".")
	git(independent, "commit", "-qm", "base")
	if out := child(independent); strings.Contains(out, `"event":"baseline_reuse"`) || !strings.Contains(out, `"event":"command_result"`) {
		t.Fatalf("independent repository reused: %s", out)
	}
	// Race readers against publication. A hit is allowed only after a complete record is visible.
	if err := os.WriteFile(cache, []byte(`{"version":2}`), 0600); err != nil {
		t.Fatal(err)
	}
	const readers = 6
	results := make([]string, readers)
	var wg sync.WaitGroup
	for i := range results {
		wg.Add(1)
		go func(i int) { defer wg.Done(); results[i] = child(other) }(i)
	}
	wg.Wait()
	for _, out := range results {
		hit, fresh := strings.Contains(out, `"event":"baseline_reuse"`), strings.Contains(out, `"event":"command_result"`)
		if hit == fresh {
			t.Fatalf("incomplete concurrent result: %s", out)
		}
	}

	for _, broken := range []string{`{`, `{"version":2}`, `{"version":999}`} {
		if err := os.WriteFile(cache, []byte(broken), 0600); err != nil {
			t.Fatal(err)
		}
		out := child(other)
		if strings.Contains(out, `"event":"baseline_reuse"`) || !strings.Contains(out, `"event":"command_result"`) {
			t.Fatalf("broken entry reused: %s", out)
		}
	}
}

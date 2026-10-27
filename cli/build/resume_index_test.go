package build

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A stopped Build's user index is custody: Resume refuses any change to what is staged, but a
// plain `git status` that only refreshes the index's stat cache is not a change (Studio Build
// 543748f1 could not be resumed after one).

// interruptedReview stops a Build during its independent review, the boundary of 543748f1.
func interruptedReview(t *testing.T) (*env, string) {
	t.Helper()
	e := newEnv(t)
	f := e.prov
	f.then(landScript(f)...)
	opened := make(chan struct{})
	f.then(f.calls("read_file", map[string]any{"path": "app.txt"}), hang(opened))
	a, done := e.startReviewed()
	<-opened
	a.s.Interrupt("SIGINT")
	<-done
	eq(t, "exit", a.exit, 130)
	id := e.onlyRun()
	cont, _ := sessionOfRun(t, e, id)
	eq(t, "stage", cont["stage"], any("review"))
	return e, id
}

// gitRefreshing runs git the way an operator's shell does, free to refresh the index.
func (e *env) gitRefreshing(args ...string) string {
	e.t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = e.root
	cmd.Env = append(append([]string{}, e.git...), "GIT_OPTIONAL_LOCKS=1")
	out, err := cmd.CombinedOutput()
	if err != nil {
		e.t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
	}
	return string(out)
}

// statRefresh makes git rewrite the index's stat cache only: a tracked file is rewritten with
// its own bytes, then `git status` notices and refreshes its entry.
func (e *env) statRefresh(path string) {
	e.t.Helper()
	full := filepath.Join(e.root, path)
	data, err := os.ReadFile(full)
	if err != nil {
		e.t.Fatal(err)
	}
	later := time.Now().Add(2 * time.Second)
	if err := os.WriteFile(full, data, 0o644); err != nil {
		e.t.Fatal(err)
	}
	if err := os.Chtimes(full, later, later); err != nil {
		e.t.Fatal(err)
	}
	e.gitRefreshing("status", "--porcelain")
}

func (e *env) indexBytes() []byte {
	e.t.Helper()
	data, err := os.ReadFile(filepath.Join(e.root, ".git/index"))
	if err != nil {
		e.t.Fatal(err)
	}
	return data
}

func TestAResumeAfterAPlainGitStatusRefreshedTheIndexContinuesTheSameReview(t *testing.T) {
	t.Parallel()
	// Direct core repair (Studio Build 543748f1): an index stat-cache refresh is not a staging change.
	e, id := interruptedReview(t)
	saved := e.indexBytes()
	e.statRefresh("README.md")
	refreshed := e.indexBytes()
	if bytes.Equal(saved, refreshed) {
		t.Fatal("git status did not refresh the index")
	}

	f := e.prov
	f.replace(submit(f, "approve"))
	r := e.resumeReviewed(id)
	if r.exit != 0 {
		t.Fatalf("exit %d\n%s\n%s", r.exit, r.shown(), r.errs)
	}
	contains(t, "stdout", r.out.String(), "landed fixture ")
	contains(t, "stderr", r.errs.String(), "kogen: the index stat cache was refreshed since Build "+id+"; staged entries are unchanged")
	// The same reviewer conversation continued: no new verification of the unchanged candidate.
	ids := e.runIDs()
	eq(t, "runs", len(ids), 2)
	child := ids[0]
	if child == id {
		child = ids[1]
	}
	cr := e.result(child)
	eq(t, "resumed_from", cr["resumed_from"], any(id))
	eq(t, "passes", cr["passes"], e.result(id)["passes"])
	review := e.jsonFile(e.runPath(child, "review-1.json"))
	eq(t, "verdict", review["verdict"], any("approve"))
	eq(t, "landed tree", e.gitOut("rev-parse", "HEAD^{tree}"), review["tree"].(string))
	events := eventsNamed(e.events(child), "resume")
	if len(events) != 1 || events[0]["index"] != "stat_refreshed" {
		t.Fatalf("resume events %v", events)
	}
	// The child's custody copy is the user's current index, which the parent's checkpoint
	// equivalently recorded.
	data, err := os.ReadFile(e.runPath(child, "index-at-start"))
	if err != nil || !bytes.Equal(data, refreshed) {
		t.Fatalf("child index-at-start differs from the refreshed index: %v", err)
	}
}

func TestAResumeStillRefusesEveryChangeToWhatIsStaged(t *testing.T) {
	t.Parallel()
	// Direct core repair (Studio Build 543748f1): only the stat cache may differ.
	blob := func(e *env, content string) string {
		cmd := exec.Command("git", "hash-object", "-w", "--stdin")
		cmd.Dir, cmd.Env, cmd.Stdin = e.root, e.git, strings.NewReader(content)
		out, err := cmd.Output()
		if err != nil {
			t.Fatal(err)
		}
		return strings.TrimSpace(string(out))
	}
	readme := func(e *env) string { return strings.Fields(e.gitRefreshing("ls-files", "--stage", "README.md"))[1] }
	cases := []struct {
		name   string
		change func(e *env)
		reason string
	}{
		{"staged content", func(e *env) {
			e.gitRefreshing("update-index", "--cacheinfo", "100644,"+blob(e, "changed\n")+",README.md")
		}, "index/staged custody changed"},
		{"a new staged path", func(e *env) {
			e.gitRefreshing("update-index", "--add", "--cacheinfo", "100644,"+blob(e, "new\n")+",staged-only.txt")
		}, "index/staged custody changed"},
		{"staged mode", func(e *env) { e.gitRefreshing("update-index", "--chmod=+x", "README.md") }, "index/staged custody changed"},
		{"assume-unchanged", func(e *env) { e.gitRefreshing("update-index", "--assume-unchanged", "README.md") }, "index/staged custody changed"},
		{"skip-worktree", func(e *env) { e.gitRefreshing("update-index", "--skip-worktree", "README.md") }, "index/staged custody changed"},
		{"intent-to-add", func(e *env) {
			e.write(".kogen/local/intent.txt", "x\n")
			e.gitRefreshing("add", "-f", "-N", ".kogen/local/intent.txt")
		}, "index/staged custody changed"},
		{"a conflict", func(e *env) {
			oid := readme(e)
			other := blob(e, "theirs\n")
			info := "0 0000000000000000000000000000000000000000\tREADME.md\n" +
				"100644 " + oid + " 1\tREADME.md\n100644 " + oid + " 2\tREADME.md\n100644 " + other + " 3\tREADME.md\n"
			cmd := exec.Command("git", "update-index", "--index-info")
			cmd.Dir, cmd.Env, cmd.Stdin = e.root, append(append([]string{}, e.git...), "GIT_OPTIONAL_LOCKS=1"), strings.NewReader(info)
			if out, err := cmd.CombinedOutput(); err != nil {
				t.Fatalf("%v %s", err, out)
			}
		}, "index/staged custody changed"},
		{"index version 4", func(e *env) { e.gitRefreshing("update-index", "--index-version", "4") }, "index/staged custody changed"},
		{"an untracked-cache extension", func(e *env) {
			e.gitRefreshing("update-index", "--untracked-cache")
			e.gitRefreshing("status", "--porcelain")
		}, "index/staged custody changed"},
		{"a damaged index", func(e *env) {
			data := e.indexBytes()
			data[len(data)-1] ^= 0xff
			if err := os.WriteFile(filepath.Join(e.root, ".git/index"), data, 0o644); err != nil {
				t.Fatal(err)
			}
		}, "index/staged custody changed"},
		{"the candidate itself (index untouched)", func(e *env) { e.write("app.txt", "edited after the stop\n") },
			"candidate contents/modes or unrelated paths changed: app.txt"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			e, id := interruptedReview(t)
			saved := e.indexBytes()
			c.change(e)
			if c.name != "the candidate itself (index untouched)" && bytes.Equal(saved, e.indexBytes()) {
				t.Fatal("the change did not reach the index")
			}
			requests := e.prov.count()
			r := e.resumeReviewed(id)
			eq(t, "exit", r.exit, 1)
			contains(t, "output", r.shown(), "candidate/resume_refused: Build "+id+": "+c.reason)
			eq(t, "requests", e.prov.count(), requests)
			eq(t, "runs", len(e.runIDs()), 1)
		})
	}
}

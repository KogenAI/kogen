package build

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"kogen/executor"
)

// Observation only: it mounts as a test with go -overlay and changes no production source. It
// runs the real `kogen intent build`, `kogen intent inspect` and `kogen intent resume` as
// processes (built from this checkout) against a temporary fixture project and the package's
// scripted provider; the external mode runs the real Build and Resume entries in process with a
// scripted Claude Code reviewer (no process, no model). It records what it saw; the assertions
// live in k_review_invalid_resume_steps.js.

var krirBuildID = regexp.MustCompile(`\(Build ([0-9a-f]{8})\)`)

// krirRepair is the native reviewer's repair: red for the fixture's acceptance check (a line
// that is exactly "red"), with a marker line a later review must never be shown.
const krirRepair = "red\nreviewer repair\n"

func krirJSON(path string) map[string]any {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var m map[string]any
	if json.Unmarshal(b, &m) != nil {
		return nil
	}
	return m
}

func krirEvents(path string) []map[string]any {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var out []map[string]any
	for _, line := range strings.Split(string(b), "\n") {
		var m map[string]any
		if strings.TrimSpace(line) != "" && json.Unmarshal([]byte(line), &m) == nil {
			out = append(out, m)
		}
	}
	return out
}

func krirNamed(events []map[string]any, name string) []any {
	out := []any{}
	for _, ev := range events {
		if ev["event"] == name {
			out = append(out, ev)
		}
	}
	return out
}

func krirGit(e *env, args ...string) string {
	cmd := exec.Command("git", args...)
	cmd.Dir = e.root
	cmd.Env = e.git
	out, err := cmd.Output()
	if err != nil {
		return "<git failed: " + err.Error() + ">"
	}
	return strings.TrimSpace(string(out))
}

func krirFile(e *env, rel string) string {
	b, err := os.ReadFile(filepath.Join(e.root, rel))
	if err != nil {
		return "<missing>"
	}
	return string(b)
}

// krirRun is what a run left: its result, checkpoint continuation, retry record and the run
// log events the assertions read.
func krirRun(e *env, id string) map[string]any {
	doc := krirJSON(e.runPath(id, "checkpoint.json"))
	state, _ := doc["state"].(map[string]any)
	cont, _ := state["continuation"].(map[string]any)
	events := krirEvents(e.runPath(id, "log.jsonl"))
	counts := map[string]any{}
	for _, name := range []string{"pass", "command", "command_result", "executor_round"} {
		counts[name] = len(krirNamed(events, name))
	}
	return map[string]any{
		"id": id, "result": krirJSON(e.runPath(id, "result.json")), "continuation": cont,
		"review_retry": state["review_retry"], "counts": counts,
		"review_only":            krirNamed(events, "review_only"),
		"review_retry_events":    krirNamed(events, "review_retry"),
		"review_edits_discarded": krirNamed(events, "review_edits_discarded"),
		"reviews":                krirNamed(events, "review"),
	}
}

func krirNewRun(e *env, seen ...string) string {
	for _, id := range e.runIDs() {
		known := false
		for _, s := range seen {
			known = known || s == id
		}
		if !known {
			return id
		}
	}
	return ""
}

func krirCLI(e *env, bin string, args ...string) map[string]any {
	code, stdout := e.cli(bin, args...)
	return map[string]any{"exit": code, "stdout": stdout}
}

// TestKReviewInvalidResumeObservation observes every mode once, in parallel, with one kogen
// program built from this checkout, and writes {mode: observation}.
func TestKReviewInvalidResumeObservation(t *testing.T) {
	bin := buildKogen(t)
	modes := []string{"native-edits", "native-repaired", "native-resumed-invalid", "external-edits"}
	outs := map[string]map[string]any{}
	for _, mode := range modes {
		outs[mode] = map[string]any{"mode": mode}
	}
	t.Cleanup(func() {
		raw, err := json.Marshal(outs)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(os.Getenv("KOGEN_KRIR_OUTPUT"), raw, 0o600); err != nil {
			t.Fatal(err)
		}
	})
	for _, mode := range modes {
		out := outs[mode]
		t.Run(mode, func(t *testing.T) {
			t.Parallel()
			if mode == "external-edits" {
				krirExternal(t, bin, out)
			} else {
				krirNative(t, bin, mode, out)
			}
		})
	}
}

// The repository lineup's direct provider route: the native reviewer of a scripted provider.
func krirNative(t *testing.T, bin, mode string, out map[string]any) {
	e := newEnv(t)
	e.credentials()
	f := e.prov
	f.then(landScript(f)...)
	rejected := func() handler {
		return submit(f, "approve", finding("blocking", "An approve verdict cannot contain a blocking finding."))
	}
	if mode == "native-repaired" {
		// Review 1 repairs app.txt to a red tree and approves it; the final verification is red
		// and goes back to the reviewer, whose two verdicts are then both rejected.
		f.then(f.calls(append(writeApp(krirRepair), "submit_review", map[string]any{"verdict": "approve", "findings": []any{}})...),
			rejected(), rejected())
	} else {
		// Review 1: two prose-only turns. Review 2 (the automatic fresh review): an uncommitted
		// edit of app.txt, then two rejected verdicts.
		f.then(prose("All good."), prose("Still good."),
			f.calls(writeApp("reviewer edit\n")...), rejected(), rejected())
	}
	start := e.head()
	stop := krirCLI(e, bin, "intent", "build", testSlug)
	out["stop"] = stop
	m := krirBuildID.FindStringSubmatch(stop["stdout"].(string))
	if m == nil {
		return
	}
	id := m[1]
	out["parent"] = krirRun(e, id)
	out["app_after_stop"] = krirFile(e, "app.txt")
	out["commits_after_stop"] = krirGit(e, "rev-list", "--count", start+"..HEAD")
	out["inspect"] = krirCLI(e, bin, "intent", "inspect", id)
	before, reviewsBefore := f.count(), len(f.reviewRequests())
	if mode == "native-resumed-invalid" {
		f.then(prose("a"), prose("b"))
	} else {
		f.then(submit(f, "approve", finding("note", "fine")))
	}
	out["resume"] = krirCLI(e, bin, "intent", "resume", id)
	reqs := f.reviewRequests()
	out["new_requests"] = f.count() - before
	out["new_review_requests"] = len(reqs) - reviewsBefore
	if len(reqs) > reviewsBefore {
		fresh := reqs[reviewsBefore]
		reused := false
		for _, old := range reqs[:reviewsBefore] {
			reused = reused || cacheKey(old) == cacheKey(fresh)
		}
		out["fresh_review"] = map[string]any{
			"input_items":         len(requestInput(fresh)),
			"same_material":       len(requestInput(fresh)) > 0 && jsonOf(requestInput(fresh)[0]) == jsonOf(requestInput(reqs[0])[0]),
			"reused_conversation": reused || cacheKey(fresh) == "",
			"has_reviewer_edit":   strings.Contains(requestText(fresh), "reviewer edit") || strings.Contains(requestText(fresh), "reviewer repair"),
		}
	}
	krirAfter(e, start, out)
	if child := krirNewRun(e, id); child != "" {
		out["child"] = krirRun(e, child)
		out["child_inspect"] = krirCLI(e, bin, "intent", "inspect", child)
	}
}

// A native builder and a Claude Code independent reviewer: both review sessions end without a
// valid verdict and the second leaves an uncommitted edit; the resume is served by the same
// scripted executor, whose third session approves.
func krirExternal(t *testing.T, bin string, out map[string]any) {
	e := newEnv(t)
	e.useExternalReviewer()
	f := e.prov
	f.then(landScript(f)...)
	x := newLineupExec(t)
	x.review = func(n int, root string, in executor.Input, task executor.Task) (executor.RoundResult, error) {
		switch sessions := len(x.starts[executor.RoleReview]); {
		case sessions >= 3:
			return executor.RoundResult{Structured: verdictJSON("approve"), Usage: harnessUsage(10, 5, 2, 0.01)}, nil
		case sessions == 2:
			lineupWriteApp(t, root, "reviewer edit\n")
		}
		return executor.RoundResult{Structured: verdictJSON("approve", blockingFinding), Usage: harnessUsage(10, 5, 2, 0.01)}, nil
	}
	start := e.head()
	a := e.build(withLineup(x))
	out["stop"] = map[string]any{"exit": a.exit, "stdout": a.shown()}
	ids := e.runIDs()
	if len(ids) != 1 {
		return
	}
	id := ids[0]
	out["parent"] = krirRun(e, id)
	out["app_after_stop"] = krirFile(e, "app.txt")
	out["commits_after_stop"] = krirGit(e, "rev-list", "--count", start+"..HEAD")
	out["inspect"] = krirCLI(e, bin, "intent", "inspect", id)
	before, sessions, builderRounds := f.count(), len(x.starts[executor.RoleReview]), len(x.rounds(executor.RoleBuild))
	r := e.resume(id, withLineupResume(x))
	out["resume"] = map[string]any{"exit": r.exit, "stdout": r.shown()}
	out["new_requests"] = f.count() - before
	out["new_review_sessions"] = len(x.starts[executor.RoleReview]) - sessions
	out["new_builder_rounds"] = len(x.rounds(executor.RoleBuild)) - builderRounds
	krirAfter(e, start, out)
	if child := krirNewRun(e, id); child != "" {
		out["child"] = krirRun(e, child)
	}
}

func krirAfter(e *env, start string, out map[string]any) {
	out["commits"] = krirGit(e, "rev-list", "--count", start+"..HEAD")
	out["committed_app"] = krirGit(e, "show", "HEAD:app.txt")
	out["head_tree"] = krirGit(e, "rev-parse", "HEAD^{tree}")
	out["app"] = krirFile(e, "app.txt")
	out["status"] = krirGit(e, "status", "--porcelain", "--untracked-files=no")
}

package build

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"kogen-loop/sys"
	"kogen/executor"
	"kogen/project"
)

// Observation only: it mounts as a test with go -overlay and changes no production source. It
// runs the real Build and the real resume entry (Resume, as `kogen intent resume` calls it) over
// the package's own fixtures: a scripted Claude Code (no process, no model) and the scripted
// provider. It records what it saw; the assertions live in k_review_resume_steps.js.

func krrJSON(path string) map[string]any {
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

func krrEvents(path string) []any {
	b, err := os.ReadFile(path)
	if err != nil {
		return []any{}
	}
	out := []any{}
	for _, line := range strings.Split(string(b), "\n") {
		var m map[string]any
		if strings.TrimSpace(line) != "" && json.Unmarshal([]byte(line), &m) == nil {
			out = append(out, m)
		}
	}
	return out
}

func krrNamed(events []any, name string) []any {
	out := []any{}
	for _, ev := range events {
		if m, _ := ev.(map[string]any); m["event"] == name {
			out = append(out, m)
		}
	}
	return out
}

func krrGit(e *env, args ...string) string {
	cmd := exec.Command("git", args...)
	cmd.Dir = e.root
	cmd.Env = e.git
	out, err := cmd.Output()
	if err != nil {
		return "<git failed: " + err.Error() + ">"
	}
	return strings.TrimSpace(string(out))
}

func krrFile(e *env, rel string) string {
	b, err := os.ReadFile(filepath.Join(e.root, rel))
	if err != nil {
		return "<missing>"
	}
	return string(b)
}

func krrAttempt(a *attempt) map[string]any {
	m := map[string]any{"exit": a.exit, "stdout": a.out.String(), "shown": a.shown(), "error": "", "detail": ""}
	if se, ok := sys.AsError(a.err); ok {
		m["error"], m["detail"] = se.Class+"/"+se.Reason, se.Detail
	} else if a.err != nil {
		m["error"], m["detail"] = "error", a.err.Error()
	}
	return m
}

// krrRun is what a run left: its result, checkpoint continuation and run log events.
func krrRun(e *env, id string) map[string]any {
	doc := krrJSON(e.runPath(id, "checkpoint.json"))
	state, _ := doc["state"].(map[string]any)
	cont, _ := state["continuation"].(map[string]any)
	return map[string]any{
		"id": id, "result": krrJSON(e.runPath(id, "result.json")), "continuation": cont,
		"executor": state["executor"], "review": state["review"], "events": krrEvents(e.runPath(id, "log.jsonl")),
	}
}

func krrOther(e *env, parent string) string {
	for _, id := range e.runIDs() {
		if id != parent {
			return id
		}
	}
	return ""
}

func TestKReviewResumeObservation(t *testing.T) {
	mode := os.Getenv("KOGEN_KRR_MODE")
	out := map[string]any{"mode": mode}
	defer func() {
		raw, err := json.Marshal(out)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(os.Getenv("KOGEN_KRR_OUTPUT"), raw, 0o600); err != nil {
			t.Fatal(err)
		}
	}()
	switch mode {
	case "builder-final-verify":
		krrBuilderFinalVerify(t, out)
	case "builder-stage":
		krrBuilderStage(t, out)
	case "review-round-limit", "review-resumed-red", "review-no-edits", "review-blocked", "review-legacy":
		krrReview(t, mode, out)
	default:
		t.Fatalf("unknown mode %q", mode)
	}
}

// A claude-code builder with the native reviewer: the reviewer's repair is approved and the
// final verification of it is stopped with SIGTERM while it runs (Build 7659baca).
func krrBuilderFinalVerify(t *testing.T, out map[string]any) {
	paused := filepath.Join(t.TempDir(), "paused")
	e := newEnv(t, func(c *project.Config) {
		c.Checks = []project.Check{{Name: "pause", Run: "if grep -qx 'reviewer repair' app.txt && ! test -f '" + paused + "'; then touch '" + paused + "'; sleep 600; fi"}}
	})
	e.useExecutor("")
	start := e.head()
	fx := newFakeExecutor(t, externalWritesApp("candidate\n", harnessUsage(1, 0, 1, 0)))
	p := e.prov
	p.then(p.calls(append(writeApp("reviewer repair\n"), "submit_review", map[string]any{"verdict": "approve", "findings": []any{}})...))
	a, done := e.start(func(in *Input) {
		in.External = func(project.Role) (executor.Executor, error) { return fx, nil }
		in.Reviewer = nil
	})
	for i := 0; i < 2400; i++ {
		if _, err := os.Stat(paused); err == nil {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	_, err := os.Stat(paused)
	out["paused"] = err == nil
	a.s.Interrupt("SIGTERM")
	<-done
	out["stop"] = krrAttempt(a)
	ids := e.runIDs()
	out["runs_after_stop"] = len(ids)
	if len(ids) != 1 {
		return
	}
	id := ids[0]
	out["parent"] = krrRun(e, id)
	requests, builds := p.count(), len(fx.tasks)
	r := e.resume(id, func(in *ResumeInput) {
		in.External = func(project.Role) (executor.Executor, error) { return fx, nil }
		in.Reviewer = nil
	})
	out["resume"] = krrAttempt(r)
	out["new_provider_requests"] = p.count() - requests
	out["new_builder_starts"] = len(fx.tasks) - builds
	out["committed_app"] = krrGit(e, "show", "HEAD:app.txt")
	out["commits"] = krrGit(e, "rev-list", "--count", start+"..HEAD")
	out["runs"] = len(e.runIDs())
	if child := krrOther(e, id); child != "" {
		out["child"] = krrRun(e, child)
	}
}

// A claude-code builder stopped at its own round limit: the builder stage stays refused.
func krrBuilderStage(t *testing.T, out map[string]any) {
	e := newEnv(t)
	e.useExecutor("    max_rounds: 1\n")
	start := e.head()
	fx := newFakeExecutor(t, externalWritesApp("red\n", harnessUsage(1, 0, 1, 0)))
	a := e.build(func(in *Input) {
		in.External = func(project.Role) (executor.Executor, error) { return fx, nil }
		in.Reviewer = nil
	})
	out["stop"] = krrAttempt(a)
	ids := e.runIDs()
	out["runs_after_stop"] = len(ids)
	if len(ids) != 1 {
		return
	}
	id := ids[0]
	out["parent"] = krrRun(e, id)
	before, _ := os.ReadFile(e.runPath(id, "checkpoint.json"))
	reached := 0
	r := e.resume(id, func(in *ResumeInput) {
		in.External = func(project.Role) (executor.Executor, error) { reached++; return fx, nil }
		in.Reviewer = nil
	})
	after, _ := os.ReadFile(e.runPath(id, "checkpoint.json"))
	out["resume"] = krrAttempt(r)
	out["executor_reached"] = reached
	out["checkpoint_same"] = string(before) == string(after)
	out["app"] = krrFile(e, "app.txt")
	out["commits"] = krrGit(e, "rev-list", "--count", start+"..HEAD")
	out["runs"] = len(e.runIDs())
	out["new_provider_requests"] = e.prov.count()
}

// claude-code serves both roles; the claude-code reviewer stops after the builder's candidate
// passed verification (Build 94901097), and a later resume is served by a new scripted
// claude-code whose builder must never run.
func krrReview(t *testing.T, mode string, out map[string]any) {
	e := newEnv(t)
	e.useLineup("    max_rounds: 2\n")
	start := e.head()
	f := newLineupExec(t)
	switch mode {
	case "review-blocked":
		f.review = func(n int, root string, in executor.Input, task executor.Task) (executor.RoundResult, error) {
			return executor.RoundResult{Structured: verdictJSON("changes", blockingFinding)}, nil
		}
	case "review-no-edits":
		f.review = func(n int, root string, in executor.Input, task executor.Task) (executor.RoundResult, error) {
			return executor.RoundResult{}, executor.Fail(executor.ReasonFailed, "the scripted reviewer process failed")
		}
	default:
		// Every round edits app.txt to a red tree and approves it: the round limit stops the Build.
		f.review = func(n int, root string, in executor.Input, task executor.Task) (executor.RoundResult, error) {
			lineupWriteApp(t, root, "red\n")
			return executor.RoundResult{Structured: verdictJSON("approve")}, nil
		}
	}
	a := e.build(withLineup(f))
	out["stop"] = krrAttempt(a)
	ids := e.runIDs()
	out["runs_after_stop"] = len(ids)
	if len(ids) != 1 {
		return
	}
	id := ids[0]
	out["parent"] = krrRun(e, id)
	out["app_before_resume"] = krrFile(e, "app.txt")
	if mode == "review-legacy" {
		doc := krrJSON(e.runPath(id, "checkpoint.json"))
		state, _ := doc["state"].(map[string]any)
		cont, _ := state["continuation"].(map[string]any)
		_, had := cont["base"]
		out["legacy_removed_base"] = had
		delete(cont, "base")
		e.writeCheckpoint(id, doc)
	}
	before, _ := os.ReadFile(e.runPath(id, "checkpoint.json"))

	g := newLineupExec(t)
	builderRounds := 0
	g.build = func(n int, root string, in executor.Input) (executor.RoundResult, error) {
		builderRounds++
		return executor.RoundResult{}, executor.Fail(executor.ReasonProtocol, "a resumed review stage must not run the builder")
	}
	if mode == "review-resumed-red" {
		g.review = f.review
	} else {
		g.review = func(n int, root string, in executor.Input, task executor.Task) (executor.RoundResult, error) {
			return executor.RoundResult{Structured: verdictJSON("approve")}, nil
		}
	}
	r := e.resume(id, func(in *ResumeInput) {
		in.External = func(project.Role) (executor.Executor, error) { return g, nil }
		in.Reviewer = nil
	})
	after, _ := os.ReadFile(e.runPath(id, "checkpoint.json"))
	out["resume"] = krrAttempt(r)
	out["checkpoint_same"] = string(before) == string(after)
	out["resumed_review_starts"] = len(g.starts[executor.RoleReview])
	out["resumed_build_starts"] = len(g.starts[executor.RoleBuild])
	out["resumed_builder_rounds"] = builderRounds
	feedback := []any{}
	for _, in := range g.rounds(executor.RoleReview) {
		feedback = append(feedback, in.Feedback)
	}
	out["resumed_review_feedback"] = feedback
	out["committed_app"] = krrGit(e, "show", "HEAD:app.txt")
	out["commits"] = krrGit(e, "rev-list", "--count", start+"..HEAD")
	out["head_tree"] = krrGit(e, "rev-parse", "HEAD^{tree}")
	out["app"] = krrFile(e, "app.txt")
	out["runs"] = len(e.runIDs())
	out["provider_requests"] = e.prov.count()
	if child := krrOther(e, id); child != "" {
		run := krrRun(e, child)
		materials := map[string]any{}
		dir := e.runPath(child, "executor-review")
		entries, _ := os.ReadDir(dir)
		for _, en := range entries {
			if strings.HasSuffix(en.Name(), "-material.json") {
				materials[en.Name()] = krrJSON(filepath.Join(dir, en.Name()))
			}
		}
		run["materials"] = materials
		run["discarded"] = krrNamed(run["events"].([]any), "review_edits_discarded")
		delete(run, "events")
		out["child"] = run
	}
	if p, ok := out["parent"].(map[string]any); ok {
		p["discarded"] = krrNamed(p["events"].([]any), "review_edits_discarded")
		delete(p, "events")
	}
}

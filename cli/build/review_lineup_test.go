package build

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"

	"kogen-loop/sys"
	"kogen/executor"
	"kogen/project"
)

// lineupExec is a scripted Claude Code (build and review roles, v2 descriptor): no process and
// no model. Every Start is a fresh session; it records each role's tasks and round inputs.
type lineupExec struct {
	t       *testing.T
	build   func(n int, root string, in executor.Input) (executor.RoundResult, error)
	review  func(n int, root string, in executor.Input, task executor.Task) (executor.RoundResult, error)
	mu      sync.Mutex
	starts  map[string][]executor.Task
	inputs  map[string][]executor.Input
	nextSeq int
}

func newLineupExec(t *testing.T) *lineupExec {
	f := &lineupExec{t: t, starts: map[string][]executor.Task{}, inputs: map[string][]executor.Input{}}
	f.build = func(n int, root string, in executor.Input) (executor.RoundResult, error) {
		return externalWritesApp("candidate\n", executor.Usage{})(n, context.Background(), root, in)
	}
	return f
}

func (f *lineupExec) Describe() executor.Descriptor {
	rc := executor.RoleCapabilities{Resume: executor.ResumeNone, Continuation: true, Usage: executor.UsageHarness,
		Prevention: []string{executor.PreventPreToolWrite}, MaxRounds: 6}
	return executor.Descriptor{Name: executor.ClaudeCode, Contract: executor.Contract, Version: "fake-claude 9.9.9",
		Capabilities:     executor.Capabilities{Roles: []string{executor.RoleBuild}, Resume: executor.ResumeNone, Continuation: true, Usage: executor.UsageHarness, MaxRounds: 6},
		RoleCapabilities: map[string]executor.RoleCapabilities{executor.RoleBuild: rc, executor.RoleReview: rc}}
}

func (f *lineupExec) Start(_ context.Context, t executor.Task, emit executor.Sink) (executor.Session, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.starts[t.Role] = append(f.starts[t.Role], t)
	f.nextSeq++
	return &lineupSession{f: f, task: t, id: t.Role + "-session-" + string(rune('0'+f.nextSeq))}, nil
}

func (f *lineupExec) rounds(role string) []executor.Input {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]executor.Input(nil), f.inputs[role]...)
}

type lineupSession struct {
	f    *lineupExec
	task executor.Task
	id   string
	n    int
}

func (s *lineupSession) Handle() executor.Handle {
	return executor.Handle{Role: s.task.Role, Executor: executor.ClaudeCode, Version: "claude-code 9.9.9", SessionID: s.id, Resume: executor.ResumeNone}
}
func (s *lineupSession) Close() error { return nil }
func (s *lineupSession) Round(_ context.Context, in executor.Input) (executor.RoundResult, error) {
	s.n++
	s.f.mu.Lock()
	s.f.inputs[s.task.Role] = append(s.f.inputs[s.task.Role], in)
	s.f.mu.Unlock()
	var res executor.RoundResult
	var err error
	if s.task.Role == executor.RoleReview {
		res, err = s.f.review(s.n, s.task.Root, in, s.task)
	} else {
		res, err = s.f.build(s.n, s.task.Root, in)
	}
	if err != nil {
		return executor.RoundResult{}, err
	}
	if res.Ending == "" {
		res.Ending = executor.EndFinish
	}
	res.Handle = s.Handle()
	return res, nil
}

func verdictJSON(verdict string, findings ...string) json.RawMessage {
	list := "[" + strings.Join(findings, ",") + "]"
	return json.RawMessage(`{"verdict":"` + verdict + `","findings":` + list + `}`)
}

const blockingFinding = `{"path":"app.txt","line":1,"severity":"blocking","message":"wrong"}`

// useLineup selects claude-code for the build and review roles (review keeps extra keys).
func (e *env) useLineup(reviewExtra string) {
	e.t.Helper()
	path := filepath.Join(e.root, ".kogen/project.yaml")
	b, err := os.ReadFile(path)
	if err != nil {
		e.t.Fatal(err)
	}
	text := string(b)
	build := regexp.MustCompile(`(?m)^  build:\n(    .*\n)+`)
	review := regexp.MustCompile(`(?m)^  review:\n(    .*\n)+`)
	if !build.MatchString(text) || !review.MatchString(text) {
		e.t.Fatalf("project.yaml lacks default roles:\n%s", text)
	}
	text = build.ReplaceAllString(text, "  build:\n    executor: claude-code\n    model: claude-sonnet-5-5\n    effort: high\n")
	text = review.ReplaceAllString(text, "  review:\n    executor: claude-code\n    model: claude-opus-5-5\n    effort: xhigh\n"+reviewExtra)
	writeFile(e.t, path, text, 0o644)
	e.run("git", "add", ".kogen/project.yaml")
	e.run("git", "commit", "-qm", "claude-code build and review")
	e.approve()
}

// withLineup injects the fake as claude-code and removes the stub reviewer: the review role
// is served by the external reviewer.
func withLineup(f *lineupExec) func(*Input) {
	return func(in *Input) {
		in.External = func(project.Role) (executor.Executor, error) { return f, nil }
		in.Reviewer = nil
	}
}

func lineupWriteApp(t *testing.T, root, content string) {
	writeFile(t, filepath.Join(root, "app.txt"), content, 0o644)
}

func (e *env) commitsSince(start string) string {
	return e.gitOut("rev-list", "--count", start+"..HEAD")
}

// TestClaudeLineupReviewExactTree: the external reviewer is a fresh session that never receives
// the builder's claims or session; an unchanged approval commits the reviewed tree; repairs are
// verified externally, red results return to the same reviewer, a blocking verdict stops with
// the edits preserved, and a claim alone, an invalid or missing verdict, or a protected write
// never commits.
func TestClaudeLineupReviewExactTree(t *testing.T) {
	t.Parallel()
	t.Run("unchanged approval commits one exact tree", func(t *testing.T) {
		t.Parallel()
		e := newEnv(t)
		e.useLineup("")
		start := e.head()
		f := newLineupExec(t)
		f.review = func(n int, root string, in executor.Input, task executor.Task) (executor.RoundResult, error) {
			return executor.RoundResult{Structured: verdictJSON("approve"), Usage: harnessUsage(10, 5, 2, 0.01)}, nil
		}
		a := e.build(withLineup(f))
		if a.exit != 0 || a.err != nil {
			t.Fatalf("exit %d err %v\n%s", a.exit, a.err, a.shown())
		}
		eq(t, "commits", e.commitsSince(start), "1")
		eq(t, "committed app.txt", e.gitOut("show", "HEAD:app.txt"), "candidate")
		tasks := f.starts[executor.RoleReview]
		if len(tasks) != 1 || tasks[0].Role != executor.RoleReview || tasks[0].Model != "claude-opus-5-5" || tasks[0].Effort != "xhigh" || len(tasks[0].Schema) == 0 {
			t.Fatalf("review tasks %+v", tasks)
		}
		var schema map[string]any
		if json.Unmarshal(tasks[0].Schema, &schema) != nil || schema["properties"].(map[string]any)["verdict"] == nil {
			t.Fatalf("schema %s", tasks[0].Schema)
		}
		brief := tasks[0].Brief.Stable + tasks[0].Brief.Dynamic
		// The reviewer gets the authority and the candidate, never the builder's claim.
		contains(t, "brief", brief, "# Intent")
		contains(t, "brief", brief, "--- app.txt")
		lacks(t, "brief", brief, "the fixture is candidate")
		lacks(t, "brief", brief, "build-session")
		id := e.onlyRun()
		res := e.result(id)
		bx, rx := res["executor"].(map[string]any), res["review_executor"].(map[string]any)
		if bx["session_id"] == rx["session_id"] || rx["name"] != "claude-code" || rx["version"] != "claude-code 9.9.9" || rx["rounds"].(float64) != 1 {
			t.Fatalf("builder %v reviewer %v", bx, rx)
		}
		if bx["usage"].(map[string]any)["input"] == rx["usage"].(map[string]any)["input"] {
			t.Fatalf("role usage is not kept separate: %v %v", bx["usage"], rx["usage"])
		}
		if len(f.rounds(executor.RoleBuild)) != 1 || len(f.rounds(executor.RoleReview)) != 1 {
			t.Fatalf("rounds %v %v", f.rounds(executor.RoleBuild), f.rounds(executor.RoleReview))
		}
	})

	t.Run("a repair is verified externally and committed", func(t *testing.T) {
		t.Parallel()
		e := newEnv(t)
		e.useLineup("")
		start := e.head()
		f := newLineupExec(t)
		f.review = func(n int, root string, in executor.Input, task executor.Task) (executor.RoundResult, error) {
			lineupWriteApp(t, root, "repaired\n")
			return executor.RoundResult{Structured: verdictJSON("approve")}, nil
		}
		a := e.build(withLineup(f))
		if a.exit != 0 {
			t.Fatalf("exit %d\n%s", a.exit, a.shown())
		}
		eq(t, "commits", e.commitsSince(start), "1")
		eq(t, "committed app.txt", e.gitOut("show", "HEAD:app.txt"), "repaired")
		if len(f.rounds(executor.RoleReview)) != 1 {
			t.Fatal("a green repair should not need another round")
		}
	})

	t.Run("red verification returns to the same reviewer", func(t *testing.T) {
		t.Parallel()
		e := newEnv(t)
		e.useLineup("")
		start := e.head()
		f := newLineupExec(t)
		f.review = func(n int, root string, in executor.Input, task executor.Task) (executor.RoundResult, error) {
			if n == 1 {
				lineupWriteApp(t, root, "red\n")
			} else {
				lineupWriteApp(t, root, "fixed by the reviewer\n")
			}
			return executor.RoundResult{Structured: verdictJSON("approve")}, nil
		}
		a := e.build(withLineup(f))
		if a.exit != 0 {
			t.Fatalf("exit %d\n%s", a.exit, a.shown())
		}
		eq(t, "commits", e.commitsSince(start), "1")
		eq(t, "committed app.txt", e.gitOut("show", "HEAD:app.txt"), "fixed by the reviewer")
		review := f.rounds(executor.RoleReview)
		if len(review) != 2 || review[0].Feedback != "" || !strings.Contains(review[1].Feedback, "is not green") || !strings.Contains(review[1].Feedback, "acceptance") {
			t.Fatalf("review inputs %+v", review)
		}
		if len(f.starts[executor.RoleReview]) != 1 || len(f.starts[executor.RoleBuild]) != 1 || len(f.rounds(executor.RoleBuild)) != 1 {
			t.Fatal("red review verification started a fresh critique or restarted the builder")
		}
	})

	t.Run("a blocking verdict stops with edits preserved", func(t *testing.T) {
		t.Parallel()
		e := newEnv(t)
		e.useLineup("")
		start := e.head()
		f := newLineupExec(t)
		f.review = func(n int, root string, in executor.Input, task executor.Task) (executor.RoundResult, error) {
			lineupWriteApp(t, root, "edited by reviewer\n")
			return executor.RoundResult{Structured: verdictJSON("changes", blockingFinding)}, nil
		}
		a := e.build(withLineup(f))
		wantStop(t, a, "candidate/review_blocked")
		eq(t, "HEAD", e.head(), start)
		eq(t, "preserved edit", e.read("app.txt"), "edited by reviewer\n")
		if len(f.rounds(executor.RoleBuild)) != 1 {
			t.Fatal("the builder was restarted")
		}
		raw, err := os.ReadFile(e.runPath(e.onlyRun(), "review-1.json"))
		if err != nil || !strings.Contains(string(raw), `"changes"`) || !strings.Contains(string(raw), "wrong") {
			t.Fatalf("findings not retained: %v %s", err, raw)
		}
	})

	t.Run("a claim, an invalid verdict, a missing verdict or a protected write never commits", func(t *testing.T) {
		cases := map[string]struct {
			round func(t *testing.T, n int, root string) (executor.RoundResult, error)
			want  string
		}{
			"claim only": {func(t *testing.T, n int, root string) (executor.RoundResult, error) {
				return executor.RoundResult{Claim: "approved, trust me"}, executor.Fail(executor.ReasonProtocol, "no structured_output")
			}, "executor/protocol"},
			"approve with a blocker": {func(t *testing.T, n int, root string) (executor.RoundResult, error) {
				return executor.RoundResult{Structured: verdictJSON("approve", blockingFinding)}, nil
			}, "candidate/review_invalid"},
			"unknown verdict": {func(t *testing.T, n int, root string) (executor.RoundResult, error) {
				return executor.RoundResult{Structured: json.RawMessage(`{"verdict":"lgtm","findings":[]}`)}, nil
			}, "candidate/review_invalid"},
			"protected write": {func(t *testing.T, n int, root string) (executor.RoundResult, error) {
				writeFile(t, filepath.Join(root, project.FeaturePath(testSlug)), "Feature: weakened\n", 0o644)
				return executor.RoundResult{Structured: verdictJSON("approve")}, nil
			}, "candidate/baseline_changed"},
			"head moved": {func(t *testing.T, n int, root string) (executor.RoundResult, error) {
				c := exec.Command("git", "-c", "user.name=x", "-c", "user.email=x@example.invalid", "commit", "-q", "--allow-empty", "--no-verify", "--no-gpg-sign", "-m", "sneaky")
				c.Dir = root
				if out, err := c.CombinedOutput(); err != nil {
					t.Fatalf("%v %s", err, out)
				}
				return executor.RoundResult{Structured: verdictJSON("approve")}, nil
			}, "candidate/head_moved"},
		}
		for name, tc := range cases {
			t.Run(name, func(t *testing.T) {
				t.Parallel()
				e := newEnv(t)
				e.useLineup("")
				start := e.head()
				f := newLineupExec(t)
				f.review = func(n int, root string, in executor.Input, task executor.Task) (executor.RoundResult, error) {
					return tc.round(t, n, root)
				}
				a := e.build(withLineup(f))
				wantStop(t, a, tc.want)
				if name != "head moved" {
					eq(t, "HEAD", e.head(), start)
				}
				if e.gitOut("rev-list", "--count", "HEAD") != e.gitOut("rev-list", "--count", start) && name != "head moved" {
					t.Fatal("a commit was created")
				}
			})
		}
	})
}

// TestClaudeLineupReviewMaterialDelivery: the complete exact source reaches the reviewer as
// Kogen-owned prompt data with its bytes and hashes retained privately, delivery counts only
// after a completed round of the matching session, and missing, changed or oversized material
// stops safely without clipping or a commit.
func TestClaudeLineupReviewMaterialDelivery(t *testing.T) {
	t.Parallel()
	big := strings.Repeat("line of a large changed file ✓\n", 20000) // about 600 KB: far over a native window
	t.Run("complete exact delivery", func(t *testing.T) {
		t.Parallel()
		e := newEnv(t)
		e.useLineup("")
		f := newLineupExec(t)
		f.build = func(n int, root string, in executor.Input) (executor.RoundResult, error) {
			lineupWriteApp(t, root, "candidate\n")
			writeFile(t, filepath.Join(root, "big.txt"), big, 0o644)
			writeFile(t, filepath.Join(root, "small.txt"), "small\n", 0o644)
			return executor.RoundResult{Claim: "done"}, nil
		}
		f.review = func(n int, root string, in executor.Input, task executor.Task) (executor.RoundResult, error) {
			return executor.RoundResult{Structured: verdictJSON("approve")}, nil
		}
		a := e.build(withLineup(f))
		if a.exit != 0 {
			t.Fatalf("exit %d\n%s", a.exit, a.shown())
		}
		task := f.starts[executor.RoleReview][0]
		contains(t, "source", task.Brief.Dynamic, big)
		contains(t, "source", task.Brief.Dynamic, "--- small.txt")
		dir := filepath.Join(e.runPath(e.onlyRun(), "executor-review"))
		for name, want := range map[string]string{"review-1-authority.txt": task.Brief.Stable, "review-1-source.txt": task.Brief.Dynamic} {
			got, err := os.ReadFile(filepath.Join(dir, name))
			if err != nil || string(got) != want {
				t.Fatalf("%s retained %d bytes (%v), sent %d", name, len(got), err, len(want))
			}
			if st, _ := os.Stat(filepath.Join(dir, name)); st.Mode().Perm() != 0o600 {
				t.Fatalf("%s mode %v", name, st.Mode().Perm())
			}
		}
		var ev reviewMaterial
		raw, _ := os.ReadFile(filepath.Join(dir, "review-1-material.json"))
		if err := json.Unmarshal(raw, &ev); err != nil {
			t.Fatal(err)
		}
		if !ev.Delivered || ev.Round != 1 || ev.Session == "" || ev.Source.SHA256 != hashHex([]byte(task.Brief.Dynamic)) || ev.Authority.SHA256 != hashHex([]byte(task.Brief.Stable)) {
			t.Fatalf("evidence %+v", ev)
		}
		paths := map[string]string{}
		for _, p := range ev.Parts {
			paths[p["path"].(string)], _ = p["sha256"].(string)
		}
		if paths["big.txt"] != hashHex([]byte(big)) || paths["small.txt"] != hashHex([]byte("small\n")) || paths["app.txt"] == "" {
			t.Fatalf("parts %v", paths)
		}
	})

	t.Run("changed or missing custody refuses an approval", func(t *testing.T) {
		for name, tamper := range map[string]func(dir string){
			"changed": func(dir string) {
				p := filepath.Join(dir, "review-1-source.txt")
				os.WriteFile(p, []byte("abbreviated"), 0o600)
			},
			"missing": func(dir string) { os.Remove(filepath.Join(dir, "review-1-source.txt")) },
		} {
			t.Run(name, func(t *testing.T) {
				t.Parallel()
				e := newEnv(t)
				e.useLineup("")
				start := e.head()
				f := newLineupExec(t)
				f.review = func(n int, root string, in executor.Input, task executor.Task) (executor.RoundResult, error) {
					matches, _ := filepath.Glob(filepath.Join(root, ".kogen/local/runs/*/executor-review"))
					if len(matches) != 1 {
						t.Fatalf("no retained material: %v", matches)
					}
					tamper(matches[0])
					return executor.RoundResult{Structured: verdictJSON("approve")}, nil
				}
				a := e.build(withLineup(f))
				wantStop(t, a, "candidate/context_custody_invalid")
				eq(t, "HEAD", e.head(), start)
			})
		}
	})

	t.Run("an oversized prompt stops without clipping or a commit", func(t *testing.T) {
		t.Parallel()
		e := newEnv(t)
		e.useLineup("")
		start := e.head()
		f := newLineupExec(t)
		f.review = func(n int, root string, in executor.Input, task executor.Task) (executor.RoundResult, error) {
			return executor.RoundResult{}, sys.Fail("candidate", "context_budget_exceeded", "over the limit", 1)
		}
		a := e.build(withLineup(f))
		wantStop(t, a, "candidate/context_budget_exceeded")
		eq(t, "HEAD", e.head(), start)
		raw, err := os.ReadFile(filepath.Join(e.runPath(e.onlyRun(), "executor-review"), "review-1-material.json"))
		if err != nil || !strings.Contains(string(raw), `"delivered": false`) {
			t.Fatalf("delivery was counted without a completed round: %v %s", err, raw)
		}
	})

	t.Run("a round without a result never counts as delivery", func(t *testing.T) {
		t.Parallel()
		e := newEnv(t)
		e.useLineup("")
		f := newLineupExec(t)
		f.review = func(n int, root string, in executor.Input, task executor.Task) (executor.RoundResult, error) {
			return executor.RoundResult{Ending: executor.EndNoCall}, nil
		}
		a := e.build(withLineup(f))
		wantStop(t, a, "executor/protocol")
		raw, _ := os.ReadFile(filepath.Join(e.runPath(e.onlyRun(), "executor-review"), "review-1-material.json"))
		if !strings.Contains(string(raw), `"delivered": false`) {
			t.Fatalf("%s", raw)
		}
	})
}

// TestClaudeLineupReviewRefusesResume: an explicit resume of an external review checkpoint is
// candidate/resume_refused before any inference or mutation, with fresh-Build guidance.
func TestClaudeLineupReviewRefusesResume(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	e.useLineup("")
	f := newLineupExec(t)
	f.review = func(n int, root string, in executor.Input, task executor.Task) (executor.RoundResult, error) {
		return executor.RoundResult{Structured: verdictJSON("changes", blockingFinding)}, nil
	}
	a := e.build(withLineup(f))
	wantStop(t, a, "candidate/review_blocked")
	id := e.onlyRun()
	head, app := e.head(), e.read("app.txt")
	cp, _ := os.ReadFile(e.runPath(id, "checkpoint.json"))
	starts, rounds := len(f.starts[executor.RoleReview]), len(f.rounds(executor.RoleReview))
	r := e.resume(id, func(in *ResumeInput) {
		in.External = func(project.Role) (executor.Executor, error) { return f, nil }
		in.Reviewer = nil
	})
	se, ok := sys.AsError(r.err)
	if !ok || se.Class != "candidate" || se.Reason != "resume_refused" {
		t.Fatalf("error %v\n%s", r.err, r.shown())
	}
	for _, part := range []string{"cannot be resumed", "fresh Build", "Build-clean", "exact approval"} {
		contains(t, "refusal", se.Detail, part)
	}
	after, _ := os.ReadFile(e.runPath(id, "checkpoint.json"))
	if string(after) != string(cp) || e.head() != head || e.read("app.txt") != app || len(e.runIDs()) != 1 {
		t.Fatal("the refused resume changed something")
	}
	if len(f.starts[executor.RoleReview]) != starts || len(f.rounds(executor.RoleReview)) != rounds {
		t.Fatal("the refused resume started a reviewer")
	}
	// The reviewer of an external checkpoint cannot be revived through the seam either.
	if _, err := (reviewExternal{}).Resume(context.Background(), nil); err == nil {
		t.Fatal("reviewExternal.Resume accepted")
	}

	// A resumed native-builder checkpoint with an external review role still reviews externally.
	t.Run("native builder checkpoint", func(t *testing.T) {
		t.Parallel()
		e := newEnv(t)
		path := filepath.Join(e.root, ".kogen/project.yaml")
		b, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		review := regexp.MustCompile(`(?m)^  review:\n(    .*\n)+`)
		writeFile(t, path, review.ReplaceAllString(string(b), "  review:\n    executor: claude-code\n    model: claude-opus-5-5\n    effort: xhigh\n"), 0o644)
		e.run("git", "add", ".kogen/project.yaml")
		e.run("git", "commit", "-qm", "claude-code review")
		e.approve()
		p := e.prov
		id, _ := e.interruptedAtRequest(p.calls("write_file", map[string]any{"path": "app.txt", "content": "candidate\n"}))
		x := newLineupExec(t)
		x.review = func(n int, root string, in executor.Input, task executor.Task) (executor.RoundResult, error) {
			return executor.RoundResult{Structured: verdictJSON("approve")}, nil
		}
		p.replace(p.calls("finish", map[string]any{"summary": "done"}))
		a := e.resume(id, func(in *ResumeInput) {
			in.External = func(project.Role) (executor.Executor, error) { return x, nil }
			in.Reviewer = nil
		})
		eq(t, "resume exit", a.exit, 0)
		eq(t, "committed app.txt", e.gitOut("show", "HEAD:app.txt"), "candidate")
		if got := len(x.starts[executor.RoleReview]); got != 1 {
			t.Fatalf("the review role started %d times, want 1", got)
		}
		if n := len(p.reviewRequests()); n != 0 {
			t.Fatalf("%d native review requests, want 0", n)
		}
	})
}

// TestClaudeLineupReviewRoundLimit: the cap is per role session (default 6, configured 1 and 2),
// exhaustion stops candidate/executor_round_limit with the work preserved, and no other role
// is restarted.
func TestClaudeLineupReviewRoundLimit(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name  string
		extra string
		max   int
	}{{"default", "", 6}, {"one", "    max_rounds: 1\n", 1}, {"two", "    max_rounds: 2\n", 2}} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			e := newEnv(t)
			e.useLineup(tc.extra)
			start := e.head()
			f := newLineupExec(t)
			// Every round approves a tree that verification finds red: the reviewer never gets it green.
			f.review = func(n int, root string, in executor.Input, task executor.Task) (executor.RoundResult, error) {
				lineupWriteApp(t, root, "red\n")
				return executor.RoundResult{Structured: verdictJSON("approve")}, nil
			}
			a := e.build(withLineup(f))
			wantStop(t, a, "candidate/executor_round_limit")
			if got := len(f.rounds(executor.RoleReview)); got != tc.max {
				t.Fatalf("%d review rounds, want %d", got, tc.max)
			}
			if len(f.starts[executor.RoleReview]) != 1 || len(f.starts[executor.RoleBuild]) != 1 || len(f.rounds(executor.RoleBuild)) != 1 {
				t.Fatal("another role or session was started")
			}
			eq(t, "HEAD", e.head(), start)
			eq(t, "preserved work", e.read("app.txt"), "red\n")
			if x := e.result(e.onlyRun())["review_executor"].(map[string]any); int(x["rounds"].(float64)) != tc.max {
				t.Fatalf("recorded rounds %v", x)
			}
		})
	}
}

// wantStop asserts the Build stopped with class/reason (shown on its output, exit 1).
func wantStop(t *testing.T, a *attempt, want string) string {
	t.Helper()
	if a.exit != 1 {
		t.Fatalf("exit %d, want a stop %s\n%s", a.exit, want, a.shown())
	}
	contains(t, "stop", a.shown(), want+":")
	return a.shown()
}

package build

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

// interrupt starts a Build whose first request hangs, interrupts it there and returns its
// run id: the checkpoint is at the builder stage, which is resumable.
func (e *env) interruptedAtRequest(first ...handler) (string, *attempt) {
	e.t.Helper()
	opened := make(chan struct{})
	e.prov.then(first...)
	e.prov.then(hang(opened))
	a, done := e.start()
	<-opened
	a.s.Interrupt("SIGINT")
	<-done
	eq(e.t, "interrupted exit", a.exit, 130)
	return e.onlyRun(), a
}

func TestAnInterruptedBuildResumesAndLandsOnceInTheSameConversation(t *testing.T) {
	t.Parallel()
	// ExUnit: test/integration/build_context_files_test.exs: cancelled initial request freezes conversation; release_behavior_test.exs: GIT-8/CLI-7 an interrupt leaves edits and restores the staged Intent index
	e := newEnv(t)
	f := e.prov
	start := e.head()
	id, a := e.interruptedAtRequest(f.calls("write_file", map[string]any{"path": "app.txt", "content": "candidate\n"}))
	out := a.out.String()
	contains(t, "stdout", out, "stopped fixture: interrupted (Build "+id+")\ncandidate/interrupted: Build "+id+" stopped by SIGINT; edits are left in place\n")
	contains(t, "stdout", out, "  edited: app.txt\n")
	contains(t, "stdout", out, "  run log: "+e.runPath(id, "log.jsonl")+"\n")
	contains(t, "stdout", out, "stopped in building: interrupted;")
	if _, ok := a.err.(interface{ ExitCode() int }); !ok {
		t.Fatalf("err %T", a.err)
	}
	res := e.result(id)
	eq(t, "outcome", res["outcome"], any("interrupted"))
	eq(t, "unknown_requests", res["unknown_requests"], any(float64(1)))
	eq(t, "app.txt", e.read("app.txt"), "candidate\n")
	eq(t, "head", e.head(), start)
	// GIT-8: the index is as the Build found it (the Intent files are not staged).
	if staged := e.gitOut("diff", "--cached", "--name-only"); staged != "" {
		t.Fatalf("staged: %s", staged)
	}
	facts := e.jsonFile(filepath.Join(e.root, ".kogen/local/facts", id+".json"))
	eq(t, "resume_status", facts["resume_status"], any("potentially_available"))
	requests := f.requests()
	if len(requests) != 2 {
		t.Fatalf("%d requests", len(requests))
	}

	f.replace(f.calls("finish", map[string]any{"summary": "done"}))
	r := e.resume(id)
	if r.exit != 0 || r.err != nil {
		t.Fatalf("exit %d err %v\n%s", r.exit, r.err, r.shown())
	}
	ids := e.runIDs()
	if len(ids) != 2 {
		t.Fatalf("runs %v", ids)
	}
	var child string
	for _, c := range ids {
		if c != id {
			child = c
		}
	}
	contains(t, "resume stdout", r.out.String(), "resuming Build "+id+" as "+child+" (root "+id+")\n")
	contains(t, "resume stdout", r.out.String(), "landed fixture ")
	all := f.requests()
	if len(all) != 3 {
		t.Fatalf("%d requests", len(all))
	}
	if !reflect.DeepEqual(all[1]["input"], all[2]["input"]) {
		t.Fatal("the resumed request is not the same conversation")
	}
	if e.gitOut("rev-list", "--count", start+"..HEAD") != "1" {
		t.Fatal("not exactly one commit")
	}
	cres := e.result(child)
	eq(t, "resumed_from", cres["resumed_from"], any(id))
	eq(t, "root_build", cres["root_build"], any(id))
	eq(t, "outcome", cres["outcome"], any("landed"))
	events := e.events(child)
	if ev := eventsNamed(events, "resume"); len(ev) != 1 || ev[0]["parent"] != id || ev[0]["root"] != id {
		t.Fatalf("resume event %v", ev)
	}
	// The conversation scope of the prompt cache and of the attempts is the root run.
	attempt := eventsNamed(events, "provider_attempt")[0]["provider"].(map[string]any)
	eq(t, "lineage", attempt["lineage"], any(id))

	// Resuming the landed run again is a no-op that names the commit.
	commit := e.head()
	again := e.resume(child)
	eq(t, "landed resume exit", again.exit, 0)
	eq(t, "landed resume stdout", again.out.String(), "Build "+child+" already landed "+commit+"\n")
	eq(t, "requests", f.count(), 3)
	eq(t, "runs", len(e.runIDs()), 2)
	// The interrupted run cannot be resumed any more: HEAD moved.
	old := e.resume(id)
	eq(t, "old exit", old.exit, 1)
	contains(t, "old", old.shown(), "candidate/resume_refused: Build "+id+": HEAD moved or uncertain commit; inspect git log;")
}

func (e *env) state() map[string]string {
	e.t.Helper()
	idx, _ := os.ReadFile(filepath.Join(e.root, ".git/index"))
	app, _ := os.ReadFile(filepath.Join(e.root, "app.txt"))
	ap, _ := os.ReadFile(filepath.Join(e.root, ".kogen/local/approvals/fixture.json"))
	return map[string]string{"head": e.gitOutSafe("rev-parse", "HEAD"), "index": string(idx), "app": string(app), "approval": string(ap)}
}

func (e *env) runFiles(id string) map[string]string {
	dir := e.runPath(id, "")
	entries, err := os.ReadDir(dir)
	if err != nil {
		e.t.Fatal(err)
	}
	out := map[string]string{}
	for _, en := range entries {
		if en.IsDir() {
			out[en.Name()+"/"] = ""
			continue
		}
		b, _ := os.ReadFile(filepath.Join(dir, en.Name()))
		out[en.Name()] = string(b)
	}
	return out
}

func TestResumeRefusals(t *testing.T) {
	t.Parallel()
	// ExUnit: test/integration/build_boundaries_test.exs: resume refuses damaged index custody, configuration and required saved state before effects; pre-clean checkpoints cannot authorize resume
	type mutation func(e *env, id string)
	setDoc := func(f func(doc, state map[string]any)) mutation {
		return func(e *env, id string) {
			doc, state := e.checkpoint(id)
			f(doc, state)
			e.writeCheckpoint(id, doc)
		}
	}
	cases := []struct {
		name   string
		prep   mutation
		want   string
		kind   string
		before func(e *env) (string, *attempt) // the interrupted Build; default at the first request
	}{
		{"damaged index backup", func(e *env, id string) {
			os.WriteFile(e.runPath(id, "index-at-start"), []byte("damaged original index"), 0o644)
		},
			"original index backup missing or damaged: ", "resume_refused", nil},
		{"index custody", func(e *env, id string) { e.write("staged.txt", "x\n"); e.run("git", "add", "staged.txt") },
			"index/staged custody changed", "resume_refused", nil},
		{"configuration", func(e *env, id string) { e.write(".kogen/project.yaml", "version: [invalid") },
			"baseline changed: .kogen/project.yaml", "resume_refused", nil},
		{"protected file", func(e *env, id string) { e.write(stepsFile, "// changed\n") },
			"baseline changed: " + stepsFile, "resume_refused", nil},
		{"approval", func(e *env, id string) {
			e.write(".kogen/local/approvals/fixture.json", strings.Replace(e.read(".kogen/local/approvals/fixture.json"), "Kogen Integration", "Somebody Else", 1))
		}, "approval changed", "resume_refused", nil},
		{"approval removed", func(e *env, id string) { os.Remove(filepath.Join(e.root, ".kogen/local/approvals/fixture.json")) },
			"approval changed", "resume_refused", nil},
		{"head moved", func(e *env, id string) { e.run("git", "commit", "-q", "--allow-empty", "-m", "moved") },
			"HEAD moved or uncertain commit; inspect git log", "resume_refused", nil},
		{"candidate drift", func(e *env, id string) { e.write("app.txt", "drift\n") },
			"candidate contents/modes or unrelated paths changed: app.txt", "resume_refused", nil},
		{"unrelated path", func(e *env, id string) { e.write("other.txt", "x\n") },
			"candidate contents/modes or unrelated paths changed: other.txt", "resume_refused", nil},
		{"another checkout", setDoc(func(doc, state map[string]any) { doc["identity"] = "/elsewhere:1:2" }),
			"another checkout identity", "resume_refused", nil},
		{"run paths", setDoc(func(doc, state map[string]any) { state["git_index"] = "/elsewhere/index" }),
			"checkpoint run/index paths changed", "resume_refused", nil},
		{"uncertain tool boundary", setDoc(func(doc, state map[string]any) {
			state["continuation"] = map[string]any{"stage": "tool", "owner": "build"}
		}), "uncertain tool boundary; inspect effects before starting a freshly approved Build", "resume_refused", nil},
		{"uncertain commit boundary", setDoc(func(doc, state map[string]any) {
			state["continuation"] = map[string]any{"stage": "commit", "tree": "abc"}
		}), "uncertain commit boundary", "resume_refused", nil},
		{"uncertain startup boundary", setDoc(func(doc, state map[string]any) { state["continuation"] = map[string]any{"stage": "startup"} }),
			"uncertain startup boundary", "resume_refused", nil},
		{"blocker", setDoc(func(doc, state map[string]any) {
			state["blocker"] = map[string]any{"classification": "BUILDER-REPORTED"}
		}),
			"protected-contract blocker requires correction and fresh approval", "resume_refused", nil},
		{"missing phase", setDoc(func(doc, state map[string]any) { delete(state, "phase") }),
			"malformed required checkpoint fields", "resume_refused", nil},
		{"unknown stage", setDoc(func(doc, state map[string]any) { state["continuation"] = map[string]any{"stage": "elsewhere"} }),
			"malformed required checkpoint fields", "resume_refused", nil},
		{"bad cache state", setDoc(func(doc, state map[string]any) {
			state["prompt_cache_states"] = map[string]any{"key": map[string]any{"id": "", "unsupported": false, "response": nil}}
		}), "malformed required checkpoint fields", "resume_refused", nil},
		{"approval of the envelope differs", setDoc(func(doc, state map[string]any) { doc["approval"] = base64.StdEncoding.EncodeToString([]byte("other")) }),
			"malformed required checkpoint fields", "resume_refused", nil},
		{"version 1", setDoc(func(doc, state map[string]any) { doc["version"] = 1 }), "incompatible checkpoint version 1", "resume_refused", nil},
		{"version 2", setDoc(func(doc, state map[string]any) { doc["version"] = 2 }), "incompatible checkpoint version 2", "resume_refused", nil},
		{"version 3 whose state is not an Elixir term", setDoc(func(doc, state map[string]any) { doc["version"] = 3 }), "malformed required checkpoint fields", "resume_refused", nil},
		{"version 999", setDoc(func(doc, state map[string]any) { doc["version"] = 999 }), "incompatible checkpoint version 999", "resume_refused", nil},
		{"version text", setDoc(func(doc, state map[string]any) { doc["version"] = "x" }), `incompatible checkpoint version "x"`, "resume_refused", nil},
		{"no version", setDoc(func(doc, state map[string]any) { delete(doc, "version") }), "malformed required checkpoint fields", "resume_refused", nil},
		{"broken json", func(e *env, id string) { os.WriteFile(e.runPath(id, "checkpoint.json"), []byte("{broken"), 0o600) },
			"malformed required checkpoint fields", "resume_refused", nil},
		{"empty object", func(e *env, id string) { os.WriteFile(e.runPath(id, "checkpoint.json"), []byte("{}"), 0o600) },
			"malformed required checkpoint fields", "resume_refused", nil},
		{"no checkpoint", func(e *env, id string) { os.Remove(e.runPath(id, "checkpoint.json")) },
			"absent or legacy checkpoint", "resume_unsupported", nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			e := newEnv(t)
			id, _ := e.interruptedAtRequest()
			c.prep(e, id)
			before, files, runs, requests := e.state(), e.runFiles(id), e.runIDs(), e.prov.count()
			r := e.resume(id)
			eq(t, "exit", r.exit, 1)
			text := r.shown()
			contains(t, "output", text, "candidate/"+c.kind+": Build "+id+": "+c.want)
			contains(t, "output", text, "inspect the checkpoint and checkout, correct drift or obtain fresh approval for a new Build\n")
			contains(t, "output", text, "  no newly created Build run;")
			if !reflect.DeepEqual(e.state(), before) {
				t.Fatalf("custody changed:\n%v\n%v", before, e.state())
			}
			if after := e.runFiles(id); !reflect.DeepEqual(after, files) && c.name != "no checkpoint" {
				t.Fatal("the evidence of the Build changed")
			}
			if !reflect.DeepEqual(e.runIDs(), runs) || e.prov.count() != requests {
				t.Fatal("a run or request was started")
			}
		})
	}
	t.Run("not an id", func(t *testing.T) {
		t.Parallel()
		e := newEnv(t)
		for _, id := range []string{"xyz", "../../etc", "DEADBEEF", ""} {
			r := e.resume(id)
			contains(t, "output "+id, r.shown(), "candidate/resume_unsupported: Build "+id+": unknown checkpoint;")
		}
	})
}

func TestResumeRefusesAnUncertainToolBoundary(t *testing.T) {
	t.Parallel()
	// ExUnit: lib/kogen/build.ex resume_locked: uncertain tool boundary (an interrupt during a shell command)
	e := newEnv(t)
	f := e.prov
	f.then(f.calls("shell", map[string]any{"command": "touch waiting; sleep 600"}))
	a, done := e.start()
	waiting := filepath.Join(e.root, "waiting")
	for i := 0; i < 500; i++ {
		if _, err := os.Stat(waiting); err == nil {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	a.s.Interrupt("SIGINT")
	<-done
	eq(t, "exit", a.exit, 130)
	id := e.onlyRun()
	facts := e.jsonFile(filepath.Join(e.root, ".kogen/local/facts", id+".json"))
	eq(t, "resume_status", facts["resume_status"], any("unsupported"))
	blockers := facts["blockers"].([]any)
	eq(t, "blocker reason", blockers[0].(map[string]any)["reason"], any("unsafe_boundary"))
	r := e.resume(id)
	eq(t, "exit", r.exit, 1)
	contains(t, "resume", r.shown(), "uncertain tool boundary; inspect effects before starting a freshly approved Build")
}

func TestResumeRefusesWorkingContextHistoryCustody(t *testing.T) {
	t.Parallel()
	// ExUnit: lib/kogen/working_context.ex validate!
	e := newEnv(t)
	id, _ := e.interruptedAtRequest()
	doc, state := e.checkpoint(id)
	state["working_context"] = map[string]any{"build": map[string]any{
		"mandatory": []any{}, "observations": []any{},
		"history": []any{map[string]any{"path": filepath.Join(e.root, ".kogen/local/runs", id, "working-context/build/1.json"), "sha256": strings.Repeat("0", 64)}},
	}}
	e.writeCheckpoint(id, doc)
	r := e.resume(id)
	eq(t, "exit", r.exit, 1)
	contains(t, "output", r.shown(), "candidate/resume_refused: working-context history custody missing, changed or unsafe: ")
}

var _ = json.Marshal

func TestAResumedRunInheritsTheEvidenceOfThePreviousRun(t *testing.T) {
	t.Parallel()
	// ExUnit: lib/kogen/local_facts.ex inherit/2 (verification and review summaries carry over a resume)
	e := newEnv(t)
	f := e.prov
	id, _ := e.interruptedAtRequest(f.calls("write_file", map[string]any{"path": "app.txt", "content": "red\n"}, "finish", map[string]any{"summary": "first"}))
	facts := e.jsonFile(filepath.Join(e.root, ".kogen/local/facts", id+".json"))
	verification := facts["verification"].([]any)
	if len(verification) != 1 {
		t.Fatalf("verification %v", verification)
	}
	first := verification[0].(map[string]any)
	eq(t, "n", first["n"], any(float64(1)))
	eq(t, "green", first["green"], any(false))
	eq(t, "path", first["path"], any(e.runPath(id, "acceptance-1.ndjson")))
	completion := e.jsonFile(filepath.Join(e.root, ".kogen/local/completion.json"))
	if len(completion["resume"].([]any)) != 1 {
		t.Fatalf("completion.json %v", completion)
	}

	f.replace(f.calls("write_file", map[string]any{"path": "app.txt", "content": "green\n"}, "finish", map[string]any{"summary": "second"}))
	r := e.resume(id)
	if r.exit != 0 {
		t.Fatalf("exit %d\n%s", r.exit, r.shown())
	}
	var child string
	for _, c := range e.runIDs() {
		if c != id {
			child = c
		}
	}
	cf := e.jsonFile(filepath.Join(e.root, ".kogen/local/facts", child+".json"))
	eq(t, "resumed_from", cf["resumed_from"], any(id))
	eq(t, "root_run", cf["root_run"], any(id))
	eq(t, "state", cf["state"], any("landed"))
	list := cf["verification"].([]any)
	if len(list) != 2 {
		t.Fatalf("verification %v", list)
	}
	inherited, own := list[0].(map[string]any), list[1].(map[string]any)
	eq(t, "inherited path", inherited["path"], any(e.runPath(id, "acceptance-1.ndjson")))
	eq(t, "own n", own["n"], any(float64(2)))
	eq(t, "own green", own["green"], any(true))
	eq(t, "own path", own["path"], any(e.runPath(child, "acceptance-2.ndjson")))
	reviews := cf["reviews"].([]any)
	if len(reviews) != 1 || reviews[0].(map[string]any)["verdict"] != "approve" {
		t.Fatalf("reviews %v", reviews)
	}
	catalog := e.jsonFile(filepath.Join(e.root, ".kogen/local/catalog.json"))
	if len(catalog) != 2 {
		t.Fatalf("catalog %v", catalog)
	}
	// The pass numbering continues across the resume.
	eq(t, "passes", e.result(child)["passes"], any(float64(2)))
	_, state := e.checkpoint(child)
	eq(t, "rounds", state["round"], any(float64(2)))
}

func TestCheckpointUsageCountsMayBeNilButNeverMalformed(t *testing.T) {
	t.Parallel()
	// ExUnit: test/kogen/run_test.exs: nullable usage counts are kept; negative, text, fractional and missing counts are refused
	e := newEnv(t)
	id, _ := e.interruptedAtRequest()
	doc, state := e.checkpoint(id)
	original, _ := os.ReadFile(e.runPath(id, "checkpoint.json"))
	decode := func(mutate func(usage, attempt map[string]any)) (*Loaded, string) {
		var d map[string]any
		if err := json.Unmarshal(original, &d); err != nil {
			t.Fatal(err)
		}
		s := d["state"].(map[string]any)
		mutate(s["usage"].(map[string]any), s["attempt_usage"].(map[string]any))
		raw, _ := json.Marshal(d)
		return decodeCheckpoint(raw, nil)
	}
	_ = doc
	_ = state
	loaded, why := decode(func(usage, attempt map[string]any) {
		usage["input"], usage["output"], usage["cached"], usage["reasoning"] = nil, float64(1), nil, nil
		for k := range attempt {
			attempt[k] = nil
		}
	})
	if why != "" {
		t.Fatal(why)
	}
	u := loaded.State.Usage
	if u.Input != nil || u.Cached != nil || u.Reasoning != nil || u.Output == nil || *u.Output != 1 {
		t.Fatalf("usage %+v", u)
	}
	for _, invalid := range []any{float64(-1), "1", 1.5} {
		_, why := decode(func(usage, attempt map[string]any) { usage["input"] = invalid })
		eq(t, "invalid count", why, "malformed required checkpoint fields")
	}
	_, why = decode(func(usage, attempt map[string]any) { delete(usage, "input") })
	eq(t, "missing count", why, "malformed required checkpoint fields")
	_, why = decode(func(usage, attempt map[string]any) { delete(attempt, "reasoning") })
	eq(t, "missing attempt count", why, "malformed required checkpoint fields")
}

func TestUnknownUsageStaysUnknownInTotals(t *testing.T) {
	t.Parallel()
	// ExUnit: lib/kogen/usage.ex add/2, line/1 and total/1 (a count that is not known stays unknown)
	known := Tokens{count(2), count(1), count(3), count(0)}
	unknown := Tokens{nil, count(1), count(1), nil}
	sum := known.plus(unknown)
	eq(t, "line", sum.Line(), "input=unknown cached=2 output=4 reasoning=unknown")
	eq(t, "unknown total", sum.Total(), "unknown")
	eq(t, "known total", known.plus(known).Total(), "10")
	eq(t, "zero", zeroTokens().Line(), "input=0 cached=0 output=0 reasoning=0")
}

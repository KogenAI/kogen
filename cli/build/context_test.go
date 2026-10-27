package build

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"kogen-loop/tools"
	"kogen/project"
	"kogen/verify"
)

func TestAConversationOverTheBudgetIsResetToALocalWorkingWindow(t *testing.T) {
	t.Parallel()
	// ExUnit: lib/kogen/working_context.ex prepare/6 (the 524288-byte request ceiling and the history archive)
	e := newEnv(t)
	f := e.prov
	big := map[string]any{"command": "head -c 20000 /dev/zero | tr '\\0' x"}
	for i := 0; i < 40; i++ {
		f.then(f.calls("shell", big))
	}
	f.then(f.calls("write_file", map[string]any{"path": "app.txt", "content": "candidate\n"}, "finish", map[string]any{"summary": "finished after resets"}))
	a := e.build()
	if a.exit != 0 {
		t.Fatalf("exit %d\n%s\n%s", a.exit, a.shown(), a.errs)
	}
	id := e.onlyRun()
	if !strings.Contains(a.errs.String(), "kogen: build local reset ") || !strings.Contains(a.errs.String(), "; ceiling 524288; reserve 131072; history ") {
		t.Fatalf("no reset reported:\n%s", a.errs)
	}
	_, state := e.checkpoint(id)
	wc := state["working_context"].(map[string]any)["build"].(map[string]any)
	history := wc["history"].([]any)
	if len(history) == 0 {
		t.Fatal("no archived window")
	}
	for i, h := range history {
		ref := h.(map[string]any)
		path := ref["path"].(string)
		want := filepath.Join(e.root, ".kogen/local/runs", id, "working-context/build", itoa(i+1)+".json")
		eq(t, "history path", path, want)
		data, err := os.ReadFile(path)
		if err != nil || hashHex(data) != ref["sha256"] {
			t.Fatalf("%s: %v", path, err)
		}
		if st, _ := os.Stat(path); st.Mode().Perm() != 0o600 {
			t.Fatalf("archive mode %v", st.Mode().Perm())
		}
		for _, dir := range []string{filepath.Dir(path), filepath.Dir(filepath.Dir(path))} {
			if st, _ := os.Stat(dir); st.Mode().Perm() != 0o700 {
				t.Fatalf("%s mode %v", dir, st.Mode().Perm())
			}
		}
		var archive struct{ Input []any }
		if err := json.Unmarshal(data, &archive); err != nil || len(archive.Input) == 0 {
			t.Fatalf("archive %v %v", archive, err)
		}
	}
	// The request after a reset carries the reset message after the opening message, and the
	// requests stay within the budget.
	var reset map[string]any
	for _, req := range f.requests() {
		raw, _ := json.Marshal(req)
		if len(raw) > 524_288+4096 {
			t.Fatalf("a request of %d bytes", len(raw))
		}
		for _, it := range req["input"].([]any) {
			m := it.(map[string]any)
			if s, ok := m["content"].(string); ok && strings.HasPrefix(s, "Local working-window reset\n") {
				reset = map[string]any{}
				if err := json.Unmarshal([]byte(strings.TrimPrefix(s, "Local working-window reset\n")), &reset); err != nil {
					t.Fatal(err)
				}
			}
		}
	}
	if reset == nil {
		t.Fatal("no reset message was sent")
	}
	eq(t, "owner", reset["owner"], any("build"))
	eq(t, "version", reset["version"], any(float64(1)))
	eq(t, "phase", reset["phase"], any("builder"))
	checks := reset["checks"].(map[string]any)
	eq(t, "checks status", checks["status"], any("not_run"))
	if reset["approval_sha256"] == "" || reset["candidate_tree"] == "" || reset["history"] == nil {
		t.Fatalf("reset %v", reset)
	}
	// The checkpoint with the archive resumes.
	events := e.events(id)
	if len(eventsNamed(events, "request")) != 41 {
		t.Fatalf("%d requests logged", len(eventsNamed(events, "request")))
	}
}

func TestAnArchivedWindowThatChangedIsRefused(t *testing.T) {
	t.Parallel()
	// ExUnit: lib/kogen/working_context.ex validate!/1 (history custody)
	e := newEnv(t)
	f := e.prov
	big := map[string]any{"command": "head -c 20000 /dev/zero | tr '\\0' x"}
	for i := 0; i < 36; i++ {
		f.then(f.calls("shell", big))
	}
	opened := make(chan struct{})
	f.then(hang(opened))
	a, done := e.start()
	<-opened
	a.s.Interrupt("SIGINT")
	<-done
	id := e.onlyRun()
	_, state := e.checkpoint(id)
	history := state["working_context"].(map[string]any)["build"].(map[string]any)["history"].([]any)
	if len(history) == 0 {
		t.Fatal("no archived window")
	}
	path := history[0].(map[string]any)["path"].(string)
	if err := os.WriteFile(path, []byte("tampered\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	requests := f.count()
	r := e.resume(id)
	eq(t, "exit", r.exit, 1)
	contains(t, "output", r.shown(), "candidate/resume_refused: working-context history custody missing, changed or unsafe: "+path+"; inspect checkpoint and archive before fresh approval\n")
	eq(t, "requests", f.count(), requests)
}

func TestTheLocalResetEqualsTheElixirReference(t *testing.T) {
	t.Parallel()
	// ExUnit: lib/kogen/working_context.ex prepare/6, replayed through the reference code (reduced input, archive bytes, history, observations)
	raw, err := os.ReadFile("testdata/reset-golden.json")
	if err != nil {
		t.Fatal(err)
	}
	var golden struct {
		Reduced      []any `json:"reduced"`
		History      []HistoryRef
		Observations []any
		Archive      string
		Tree         string
	}
	dec := json.NewDecoder(strings.NewReader(string(raw)))
	dec.UseNumber()
	if err := dec.Decode(&golden); err != nil {
		t.Fatal(err)
	}
	var archived struct{ Input []any }
	adec := json.NewDecoder(strings.NewReader(golden.Archive))
	adec.UseNumber()
	if err := adec.Decode(&archived); err != nil {
		t.Fatal(err)
	}

	e := newEnv(t)
	root := e.root
	run, err := StartRun(root)
	if err != nil {
		t.Fatal(err)
	}
	approval := encodeBase64([]byte(`{"sha256":"` + strings.Repeat("a", 64) + `"}`))
	repo := e.gitRepo()
	b := &Attempt{
		State: State{
			Root: root, Start: e.head(), Excluded: []string{}, Repairs: 2, Run: run, ApprovalBytes: approval,
			Continuation: Continuation{Stage: StageBuilder, Input: archived.Input}, WorkingContext: map[string]*OwnerContext{},
		},
		deps: e.deps(), repo: repo, cache: nil, s: sessionOf(e),
	}
	tools := []any{map[string]any{"type": "function", "name": "sample", "parameters": map[string]any{"type": "object"}}}
	reduced, err := b.prepareContext("build", defaultRole(), "policy text", archived.Input, tools)
	if err != nil {
		t.Fatal(err)
	}
	got, _ := encodeJSON(reduced)
	want, _ := encodeJSON(golden.Reduced)
	// The Elixir run named its own folder: paths are compared with the root replaced.
	gotText := strings.ReplaceAll(string(got), run.Dir, "<ROOT>/.kogen/local/runs/abcd1234")
	// Both sides name the tree of their own repository's candidate.
	tree, err := repo.Tree(b.Start, nil)
	if err != nil {
		t.Fatal(err)
	}
	gotText = strings.ReplaceAll(gotText, tree, golden.Tree)
	if gotText != string(want) {
		t.Fatalf("reduced input differs\n got: %.600s\nwant: %.600s", gotText, want)
	}
	state := b.WorkingContext["build"]
	if len(state.History) != 1 {
		t.Fatalf("history %v", state.History)
	}
	eq(t, "archive sha256", state.History[0].SHA256, golden.History[0].SHA256)
	data, _ := os.ReadFile(state.History[0].Path)
	eq(t, "archive bytes", string(data), golden.Archive)
	gotObs, _ := encodeJSON(state.Observations)
	wantObs, _ := encodeJSON(golden.Observations)
	eq(t, "observations", string(gotObs), string(wantObs))
}

// windowAttempt is an Attempt in a review stage with a green pass over the current tree, for
// the working-context tests.
func windowAttempt(t *testing.T) (*Attempt, *env, string) {
	t.Helper()
	e := newEnv(t)
	repo := e.gitRepo()
	start := e.head()
	tree, err := repo.Tree(start, nil)
	if err != nil {
		t.Fatal(err)
	}
	run, err := StartRun(e.root)
	if err != nil {
		t.Fatal(err)
	}
	b := &Attempt{
		State: State{
			Root: e.root, Start: start, Excluded: []string{}, Run: run, Phase: "building", Repairs: 1,
			Continuation: Continuation{Stage: StageReview}, WorkingContext: map[string]*OwnerContext{},
			LastPass:      &verify.Pass{Green: true, Tree: tree, Clean: true},
			LastReview:    &ReviewRecord{Findings: []map[string]any{{"severity": "blocking", "message": "unresolved blocker"}}},
			ApprovalBytes: encodeBase64([]byte(`{"sha256":"` + hashHex([]byte("exact approval")) + `"}`)),
		},
		deps: e.deps(), repo: repo, s: sessionOf(e),
	}
	return b, e, tree
}

func TestResetsRetainObservationsTheLatestExchangeAndPrivateExactHistoryNotStaleGreen(t *testing.T) {
	t.Parallel()
	// ExUnit: test/integration/working_context_test.exs: chatgpt and opencode-go resets retain observations, complete latest exchange and private exact history, not stale green
	for _, role := range []project.Role{
		{Model: "fixture", Effort: "high"},
		{Provider: "opencode-go", Model: "kimi-k3", Effort: "high"},
	} {
		name := role.Provider
		if name == "" {
			name = "chatgpt"
		}
		t.Run(name, func(t *testing.T) { resetRetains(t, role) })
	}
}

func resetRetains(t *testing.T, role project.Role) {
	b, e, tree := windowAttempt(t)
	authority := map[string]any{"role": "user", "content": "exact approved authority Δ🙂\r\n"}
	diagnostic := map[string]any{"role": "user", "content": "private frozen diagnostic, not authority"}
	var groups [][]any
	for i := 1; i <= 3; i++ {
		args, _ := json.Marshal(map[string]any{"path": "app.txt", "content": strings.Repeat("x", 190_000)})
		call := "call" + itoa(i)
		message := map[string]any{"type": "message", "role": "assistant", "phase": "commentary",
			"content": []any{map[string]any{"type": "output_text", "text": "UNFINISHED " + itoa(i) + "\nΔ🙂"}}}
		function := map[string]any{"type": "function_call", "call_id": call, "name": "write_file", "arguments": string(args)}
		output := map[string]any{"type": "function_call_output", "call_id": call, "output": "ok"}
		if role.Provider == "opencode-go" {
			// The chat-compatible route keeps its raw assistant message with the replayed item.
			message["opencode_go_message"] = map[string]any{
				"role": "assistant", "content": "UNFINISHED", "reasoning": "opaque Δ",
				"reasoning_details": []any{map[string]any{"type": "reasoning.text", "index": 0, "vendor": []any{2, 1}}},
				"tool_calls": []any{map[string]any{"id": call, "type": "function",
					"function": map[string]any{"name": "write_file", "arguments": string(args)}}},
			}
			groups = append(groups, []any{message, function, output})
			continue
		}
		groups = append(groups, []any{
			map[string]any{"type": "reasoning", "encrypted_content": "opaque+/==\nΔ" + itoa(i), "summary": []any{}},
			message, function, output,
		})
	}
	input := []any{authority, diagnostic}
	for _, g := range groups {
		input = append(input, g...)
	}

	// A milestone of a staged Build: verified at this tree, historical once the tree moves.
	plan := []stageDef{
		{ID: "foundation", Title: "Foundation", Goal: "Runnable core", Checks: []string{"true"}},
		{ID: "surface", Title: "Surface", Goal: "Integrate", Checks: []string{"true"}},
	}
	milestone, err := b.retainStage(StageEvidence{
		Pass: verify.Pass{N: 1, Tree: tree, Clean: true, Green: true}, StageID: "foundation", Index: 1, Contract: b.ApprovalBytes,
	})
	if err != nil {
		t.Fatal(err)
	}
	active := "surface"
	b.StagePlan = plan
	b.StageProgress = &StageProgress{Total: 2, Completed: []string{"foundation"}, Active: &active, Phase: phaseStage}
	b.StageEvidence = []StageEvidence{milestone}

	e.write("app.txt", "edited after green\n")
	got, err := b.prepareContext("review", role, "policy", input, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got[:2], []any{authority, diagnostic}) {
		t.Fatal("the mandatory opening messages are not kept exactly")
	}
	last := groups[2]
	if !reflect.DeepEqual(got[len(got)-len(last):], last) {
		t.Fatal("the latest exchange is not kept whole")
	}
	var reset map[string]any
	content := got[2].(map[string]any)["content"].(string)
	if err := json.Unmarshal([]byte(strings.TrimPrefix(content, "Local working-window reset\n")), &reset); err != nil {
		t.Fatal(err)
	}
	eq(t, "phase", reset["phase"], any("review"))
	navigation, _ := reset["stage_navigation"].(string)
	for _, part := range []string{"Active stage 2/2", "historical", tree} {
		contains(t, "stage navigation", navigation, part)
	}
	eq(t, "progress kept", b.StageProgress.value()["phase"], any("stage"))
	eq(t, "evidence kept", len(b.StageEvidence), 1)
	checks := reset["checks"].(map[string]any)
	if checks["status"] != "stale" || checks["candidate_tree"] != tree || len(checks["failing"].([]any)) != 0 || len(checks["not_run"].([]any)) != 0 {
		t.Fatalf("checks %v", checks)
	}
	if f := reset["findings"].([]any); len(f) != 1 || f[0].(map[string]any)["message"] != "unresolved blocker" {
		t.Fatalf("findings %v", f)
	}
	eq(t, "unfinished", len(reset["unfinished"].([]any)), 3)
	eq(t, "approval", reset["approval_sha256"], any(hashHex([]byte("exact approval"))))
	history := reset["history"].([]any)
	if len(history) != 1 {
		t.Fatalf("history %v", history)
	}
	ref := history[0].(map[string]any)
	data, err := os.ReadFile(ref["path"].(string))
	if err != nil || hashHex(data) != ref["sha256"] {
		t.Fatalf("archive: %v", err)
	}
	var archived struct{ Input []any }
	if err := json.Unmarshal(data, &archived); err != nil || canonical(archived.Input) != canonical(input) {
		t.Fatalf("the archive does not hold the exact input: %v", err)
	}
	if err := b.validateWorkingContext(); err != nil {
		t.Fatal(err)
	}
	if m, err := tools.Measure(b.bodyOf(role, "policy", got, nil, "review")); err != nil || !m.Fits {
		t.Fatalf("the reset conversation does not fit: %v %+v", err, m)
	}
	runs := filepath.Join(e.root, ".kogen/local/runs")
	if err := os.Rename(runs, runs+"-moved"); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(runs+"-moved", runs); err != nil {
		t.Fatal(err)
	}
	err = b.validateWorkingContext()
	if err == nil || !strings.Contains(err.Error(), "history custody missing, changed or unsafe") {
		t.Fatalf("a symbolic link in the custody chain is accepted: %v", err)
	}
	os.Remove(runs)
	os.Rename(runs+"-moved", runs)
	if err := os.WriteFile(ref["path"].(string), []byte("changed"), 0o600); err != nil {
		t.Fatal(err)
	}
	err = b.validateWorkingContext()
	if err == nil || !strings.Contains(err.Error(), "inspect checkpoint and archive before fresh approval") {
		t.Fatalf("a changed archive is accepted: %v", err)
	}
}

func TestIrreducibleAuthorityRefusesWithoutArchiveOrCheckoutChanges(t *testing.T) {
	t.Parallel()
	// ExUnit: test/integration/working_context_test.exs: irreducible authority refuses without archive or checkout changes
	b, e, _ := windowAttempt(t)
	input := []any{map[string]any{"role": "user", "content": strings.Repeat("x", 600_000)}}
	index := e.state()["index"]
	_, err := b.prepareContext("build", project.Role{Model: "fixture", Effort: "high"}, "policy", input, nil)
	if err == nil {
		t.Fatal("an irreducible request is accepted")
	}
	for _, part := range []string{"candidate/context_budget_exceeded: build: measured ", "mandatory ", "ceiling 524288, output reserve 131072 tokens", "checkpoint.json", "ordinary Refine and new exact approval"} {
		contains(t, "error", err.Error(), part)
	}
	if _, err := os.Stat(filepath.Join(b.Run.Dir, "working-context")); !os.IsNotExist(err) {
		t.Fatal("an archive was written")
	}
	eq(t, "index", e.state()["index"], index)
}

package conformance

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// runFixture plays a recorded case through the built CLI.
func runFixture(t *testing.T, name string) (result, *fakeProvider, *world, fixture) {
	t.Helper()
	fx := loadFixture(t, name)
	w := newWorld(t).signIn().seed(fx.Files)
	f := newFakeProvider(t, fx.Exchanges)
	r := runCLI(t, w, f, w.task(fx.Task))
	return r, f, w, fx
}

func TestFixtures(t *testing.T) {
	names, err := filepath.Glob("testdata/*.json")
	if err != nil || len(names) == 0 {
		t.Fatalf("no fixtures: %v", err)
	}
	for _, path := range names {
		name := strings.TrimSuffix(filepath.Base(path), ".json")
		t.Run(name, func(t *testing.T) {
			r, f, _, fx := runFixture(t, name)
			if r.exit != fx.Expect.Exit {
				t.Errorf("exit %d, want %d (stderr: %s)", r.exit, fx.Expect.Exit, r.stderr)
			}
			if got := len(f.requests()); got != fx.Expect.Requests {
				t.Errorf("the provider saw %d requests, want %d", got, fx.Expect.Requests)
			}
			expectEvents(t, r, fx.Expect.Events)
		})
	}
}

func sha(text string) string {
	sum := sha256.Sum256([]byte(text))
	return hex.EncodeToString(sum[:])
}

func TestToolEventsCarryHashesOfWhatTheModelSaw(t *testing.T) {
	r, f, _, fx := runFixture(t, "terminal")
	if r.exit != 0 {
		t.Fatal(r.stderr)
	}
	args := fx.Exchanges[0].Items[0]["arguments"].(string)
	if got := r.all("tool.call")[0]["arguments_sha256"]; got != sha(args) {
		t.Errorf("arguments_sha256 %v, want %s", got, sha(args))
	}
	// The result the model received is the function_call_output of the second request.
	input := f.requests()[1]["input"].([]any)
	var output string
	for _, it := range input {
		if m := it.(map[string]any); m["type"] == "function_call_output" && m["call_id"] == "c1" {
			output = m["output"].(string)
		}
	}
	if output == "" {
		t.Fatalf("the second request has no output for c1: %v", input)
	}
	res := r.all("tool.result")[0]
	if res["result_sha256"] != sha(output) || int(res["bytes"].(float64)) != len(output) {
		t.Errorf("tool.result %v does not describe the output %q", res, output)
	}
}

func TestToolResultIsCutAt16384BytesIncludingTheMarker(t *testing.T) {
	r, f, _, _ := runFixture(t, "tool_result_cut")
	if r.exit != 0 {
		t.Fatal(r.stderr)
	}
	var output string
	for _, it := range f.requests()[1]["input"].([]any) {
		if m := it.(map[string]any); m["type"] == "function_call_output" && m["call_id"] == "c1" {
			output = m["output"].(string)
		}
	}
	if len(output) == 0 || len(output) > 16384 {
		t.Fatalf("the model received %d bytes, want 1..16384", len(output))
	}
	if !strings.Contains(output, "bytes omitted") {
		t.Errorf("the cut has no marker: %q", output[:200])
	}
	if got := int(r.all("tool.result")[0]["bytes"].(float64)); got != len(output) {
		t.Errorf("tool.result bytes %d, the model received %d", got, len(output))
	}
}

func TestTerminalInTheMiddleOfABatchLeavesItUnanswered(t *testing.T) {
	r, f, _, _ := runFixture(t, "multi_call_terminal_in_middle")
	if r.exit != 0 {
		t.Fatal(r.stderr)
	}
	if got := len(f.requests()); got != 1 {
		t.Errorf("%d requests, want 1: nothing is sent after a terminal batch", got)
	}
	for _, ev := range r.all("tool.result") {
		if ev["call_id"] == "c2" {
			t.Errorf("the terminal call has a result: %v", ev)
		}
	}
}

func TestUsageUnknownStaysNullOnTheWire(t *testing.T) {
	r, _, _, _ := runFixture(t, "usage_unknown")
	if r.exit != 0 {
		t.Fatal(r.stderr)
	}
	for _, typ := range []string{"response", "round.ended"} {
		var line string
		for i, ev := range r.events {
			if ev["type"] == typ {
				line = r.lines[i]
			}
		}
		for _, field := range []string{`"input":null`, `"cached":null`, `"output":null`, `"reasoning":null`, `"state":"unknown"`, `"source":"provider"`} {
			if !strings.Contains(line, field) {
				t.Errorf("%s line lacks %s: %s", typ, field, line)
			}
		}
	}
}

func TestClaimIsBoundedTo16384Bytes(t *testing.T) {
	w := newWorld(t).signIn()
	long := strings.Repeat("x", 40000)
	f := newFakeProvider(t, []exchange{{Items: []map[string]any{call("c1", "finish", map[string]any{"summary": long})}}})
	r := runCLI(t, w, f, w.task(nil))
	if r.exit != 0 {
		t.Fatal(r.stderr)
	}
	claim := r.first("round.ended")["claim"].(string)
	if len(claim) > 16384 || !strings.Contains(claim, "bytes omitted") {
		t.Errorf("claim is %d bytes; want at most 16384 with the cut marker", len(claim))
	}
}

func TestCustomTerminalNameEndsTheRound(t *testing.T) {
	w := newWorld(t).signIn()
	f := newFakeProvider(t, []exchange{{Items: []map[string]any{call("c1", "report", map[string]any{"summary": "mine"})}}})
	r := runCLI(t, w, f, w.task(map[string]any{"terminal": []any{"report"}}))
	if r.exit != 0 {
		t.Fatal(r.stderr)
	}
	if got := r.first("round.ended")["terminal_tool"]; got != "report" {
		t.Errorf("terminal_tool %v", got)
	}
	// The model was offered the terminal tool it is allowed to end with.
	tools := f.requests()[0]["tools"].([]any)
	names := []string{}
	for _, d := range tools {
		names = append(names, d.(map[string]any)["name"].(string))
	}
	if names[len(names)-1] != "report" || strings.Contains(strings.Join(names, ","), "finish") {
		t.Errorf("tool names %v", names)
	}
}

// ---- refusals before any request ----

func expectRefusal(t *testing.T, r result, f *fakeProvider, class, reason string, exit int) {
	t.Helper()
	if r.exit != exit {
		t.Errorf("exit %d, want %d (stderr: %s)", r.exit, exit, r.stderr)
	}
	e := r.first("error")
	if e == nil {
		t.Fatalf("no error event: %v", r.types())
	}
	if e["class"] != class || e["reason"] != reason || e["detail"] == "" {
		t.Errorf("error %v, want %s/%s with a detail", e, class, reason)
	}
	if f != nil && len(f.requests()) != 0 {
		t.Errorf("%d requests were sent", len(f.requests()))
	}
	if r.first("round.ended") != nil {
		t.Error("a refused task ended a round")
	}
	end := r.events[len(r.events)-1]
	if end["status"] != "failed" {
		t.Errorf("session.ended %v", end)
	}
}

func TestStrictTaskRefusal(t *testing.T) {
	w := newWorld(t).signIn()
	base, _ := json.Marshal(w.task(nil))
	extra := map[string]any{}
	json.Unmarshal(base, &extra)
	extra["surprise"] = true
	withExtra, _ := json.Marshal(extra)
	nested := map[string]any{}
	json.Unmarshal(base, &nested)
	nested["session"] = map[string]any{"dir": "", "resume": false, "extra": 1}
	withNested, _ := json.Marshal(nested)
	for name, task := range map[string]string{
		"unknown field":        string(withExtra),
		"unknown nested field": string(withNested),
		"trailing data":        string(base) + "\n{}",
		"not json":             "this is not a task",
		"wrong type":           `{"protocol":"kogen-loop/v1","root":5}`,
		"empty":                "",
	} {
		t.Run(name, func(t *testing.T) {
			f := newFakeProvider(t, nil)
			r := runCLIRaw(t, w, f, []byte(task))
			expectRefusal(t, r, f, "loop", "invalid_task", 2)
			if r.first("session.started") != nil {
				t.Error("a refused task started a session")
			}
		})
	}
}

func TestUnsupportedProtocolIsRefusedBeforeItsFieldsAreJudged(t *testing.T) {
	w := newWorld(t).signIn()
	for name, task := range map[string]string{
		"other version":  `{"protocol":"kogen-loop/v2","fields_of_the_future":true}`,
		"missing":        `{"root":"/"}`,
		"another family": `{"protocol":"other/v1"}`,
	} {
		t.Run(name, func(t *testing.T) {
			f := newFakeProvider(t, nil)
			r := runCLIRaw(t, w, f, []byte(task))
			expectRefusal(t, r, f, "loop", "unsupported_protocol", 2)
		})
	}
}

func TestRequiresRefusal(t *testing.T) {
	for _, name := range []string{"subagents", "compaction", "telepathy"} {
		t.Run(name, func(t *testing.T) {
			w := newWorld(t).signIn()
			f := newFakeProvider(t, nil)
			r := runCLI(t, w, f, w.task(map[string]any{"requires": []any{"session_resume", name}}))
			expectRefusal(t, r, f, "loop", "unsupported_capability", 2)
			if e := r.first("error")["detail"].(string); !strings.Contains(e, name) {
				t.Errorf("the refusal does not name %q: %s", name, e)
			}
		})
	}
	t.Run("provided capabilities are accepted", func(t *testing.T) {
		w := newWorld(t).signIn()
		f := newFakeProvider(t, []exchange{{Items: []map[string]any{message("ok")}}})
		r := runCLI(t, w, f, w.task(map[string]any{"requires": []any{"session_resume", "images"}}))
		if r.exit != 0 {
			t.Errorf("exit %d: %v", r.exit, r.events)
		}
	})
}

func TestInvalidTaskFields(t *testing.T) {
	cases := map[string]func(w *world) map[string]any{
		"root missing": func(w *world) map[string]any { return map[string]any{"root": filepath.Join(w.root, "nope")} },
		"root is file": func(w *world) map[string]any {
			p := filepath.Join(w.root, "file")
			os.WriteFile(p, nil, 0o644)
			return map[string]any{"root": p}
		},
		"empty prompt":      func(w *world) map[string]any { return map[string]any{"prompt": ""} },
		"unknown tool":      func(w *world) map[string]any { return map[string]any{"tools": []any{"read_file", "teleport"}} },
		"negative deadline": func(w *world) map[string]any { return map[string]any{"deadline_seconds": -1} },
		"resume without dir": func(w *world) map[string]any {
			return map[string]any{"session": map[string]any{"dir": "", "resume": true}}
		},
		"unknown provider": func(w *world) map[string]any {
			return map[string]any{"role": map[string]any{"provider": "nobody", "model": "m", "effort": "e", "base_url": ""}}
		},
		"terminal clashes with a tool": func(w *world) map[string]any { return map[string]any{"terminal": []any{"shell"}} },
	}
	for name, over := range cases {
		t.Run(name, func(t *testing.T) {
			w := newWorld(t).signIn()
			f := newFakeProvider(t, nil)
			r := runCLI(t, w, f, w.task(over(w)))
			expectRefusal(t, r, f, "loop", "invalid_task", 2)
		})
	}
}

func TestLoginRequiredBeforeAnyRequest(t *testing.T) {
	w := newWorld(t) // no credential
	f := newFakeProvider(t, []exchange{{Items: []map[string]any{message("never")}}})
	r := runCLI(t, w, f, w.task(nil))
	expectRefusal(t, r, f, "provider", "login", 1)
}

func TestOverBudgetRequestIsRefusedBeforeAnyRequest(t *testing.T) {
	w := newWorld(t).signIn()
	f := newFakeProvider(t, []exchange{{Items: []map[string]any{message("never")}}})
	r := runCLI(t, w, f, w.task(map[string]any{"prompt": strings.Repeat("a", 600_000)}))
	expectRefusal(t, r, f, "loop", "context_budget_exceeded", 1)
	if r.first("round.ended") != nil || r.first("response") != nil {
		t.Error("the refused request produced a response or ending")
	}
}

func TestProviderFailureIsAnErrorEventWithExit1(t *testing.T) {
	w := newWorld(t).signIn()
	f := newFakeProvider(t, []exchange{{Status: 400}})
	r := runCLI(t, w, f, w.task(nil))
	if r.exit != 1 {
		t.Errorf("exit %d", r.exit)
	}
	e := r.first("error")
	if e == nil || e["class"] != "provider" {
		t.Errorf("error %v", e)
	}
	if end := r.events[len(r.events)-1]; end["status"] != "failed" || end["exit"] != float64(1) {
		t.Errorf("session.ended %v", end)
	}
}

// ---- deadline and interruption (process custody) ----

const sleeper = `echo $$ > pid-sh; sleep 600 & echo $! > pid-sleep; wait`

func readPid(t *testing.T, path string) int {
	t.Helper()
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		if data, err := os.ReadFile(path); err == nil && strings.HasSuffix(string(data), "\n") {
			if pid, err := strconv.Atoi(strings.TrimSpace(string(data))); err == nil {
				return pid
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("%s never appeared", path)
	return 0
}

func TestDeadlineEndsAHangingRequest(t *testing.T) {
	w := newWorld(t).signIn()
	f := newFakeProvider(t, []exchange{{Hang: true}})
	start := time.Now()
	r := runCLI(t, w, f, w.task(map[string]any{"deadline_seconds": 1}))
	if time.Since(start) > 20*time.Second {
		t.Errorf("the deadline took %v", time.Since(start))
	}
	if r.exit != 1 {
		t.Errorf("exit %d", r.exit)
	}
	e := r.first("error")
	if e == nil || e["class"] != "loop" || e["reason"] != "deadline" {
		t.Errorf("error %v", e)
	}
	if end := r.events[len(r.events)-1]; end["status"] != "failed" {
		t.Errorf("session.ended %v", end)
	}
}

func TestDeadlineTerminatesARunningShellGroup(t *testing.T) {
	w := newWorld(t).signIn()
	f := newFakeProvider(t, []exchange{{Items: []map[string]any{call("c1", "shell", map[string]any{"command": sleeper})}}})
	p := startCLI(t, w, f, mustJSON(t, w.task(map[string]any{"deadline_seconds": 3})), "run", "--task", "-")
	pidSh := readPid(t, filepath.Join(w.root, "pid-sh"))
	pidSleep := readPid(t, filepath.Join(w.root, "pid-sleep"))
	r := p.result()
	if r.exit != 1 {
		t.Errorf("exit %d (stderr %s)", r.exit, r.stderr)
	}
	if e := r.first("error"); e == nil || e["reason"] != "deadline" {
		t.Errorf("error %v", e)
	}
	for _, pid := range []int{pidSh, pidSleep} {
		if !pidGone(pid) {
			t.Errorf("process %d survived the deadline", pid)
		}
	}
}

func TestInterruptionTerminatesTheShellGroup(t *testing.T) {
	for _, tc := range []struct {
		name string
		sig  syscall.Signal
		exit int
	}{{"SIGINT", syscall.SIGINT, 130}, {"SIGTERM", syscall.SIGTERM, 143}} {
		t.Run(tc.name, func(t *testing.T) {
			w := newWorld(t).signIn()
			f := newFakeProvider(t, []exchange{{Items: []map[string]any{call("c1", "shell", map[string]any{"command": sleeper})}}})
			p := startCLI(t, w, f, mustJSON(t, w.task(nil)), "run", "--task", "-")
			pidSh := readPid(t, filepath.Join(w.root, "pid-sh"))
			pidSleep := readPid(t, filepath.Join(w.root, "pid-sleep"))
			if err := p.cmd.Process.Signal(tc.sig); err != nil {
				t.Fatal(err)
			}
			r := p.result()
			if r.exit != tc.exit {
				t.Errorf("exit %d, want %d (stderr %s)", r.exit, tc.exit, r.stderr)
			}
			end := r.events[len(r.events)-1]
			if end["status"] != "interrupted" || end["exit"] != float64(tc.exit) {
				t.Errorf("session.ended %v", end)
			}
			if r.first("round.ended") != nil {
				t.Error("an interrupted round ended")
			}
			for _, pid := range []int{pidSh, pidSleep} {
				if !pidGone(pid) {
					t.Errorf("process %d survived the interruption", pid)
				}
			}
			if got := len(f.requests()); got != 1 {
				t.Errorf("%d requests, want 1", got)
			}
		})
	}
}

func TestKilledHostStillTakesTheShellGroupDown(t *testing.T) {
	w := newWorld(t).signIn()
	f := newFakeProvider(t, []exchange{{Items: []map[string]any{call("c1", "shell", map[string]any{"command": sleeper})}}})
	p := startCLI(t, w, f, mustJSON(t, w.task(nil)), "run", "--task", "-")
	pidSh := readPid(t, filepath.Join(w.root, "pid-sh"))
	pidSleep := readPid(t, filepath.Join(w.root, "pid-sleep"))
	if err := p.cmd.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	<-p.done
	for _, pid := range []int{pidSh, pidSleep} {
		if !pidGone(pid) {
			t.Errorf("process %d survived the death of the host (the supervisor did not stop its group)", pid)
		}
	}
}

func mustJSON(t *testing.T, v any) []byte {
	t.Helper()
	data, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

// ---- session resume ----

func transcriptOf(t *testing.T, dir string) map[string]any {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(dir, "session.json"))
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(data, &m); err != nil {
		t.Fatal(err)
	}
	return m
}

func sessionTask(w *world, dir string, resume bool, over map[string]any) map[string]any {
	task := w.task(map[string]any{"session": map[string]any{"dir": dir, "resume": resume}})
	for k, v := range over {
		task[k] = v
	}
	return task
}

func TestTranscriptResumeAfterATerminalEnding(t *testing.T) {
	w := newWorld(t).signIn()
	dir := filepath.Join(t.TempDir(), "transcript")
	f := newFakeProvider(t, []exchange{
		{Items: []map[string]any{call("c1", "finish", map[string]any{"summary": "first"})}},
		{Items: []map[string]any{message("second answer")}},
	})
	first := runCLI(t, w, f, sessionTask(w, dir, false, map[string]any{"prompt": "start"}))
	if first.exit != 0 {
		t.Fatal(first.stderr)
	}
	// session.json: 0600 file in a 0700 directory, with the contract's fields.
	if st, err := os.Stat(dir); err != nil || st.Mode().Perm() != 0o700 {
		t.Errorf("directory %v %v", st, err)
	}
	if st, err := os.Stat(filepath.Join(dir, "session.json")); err != nil || st.Mode().Perm() != 0o600 {
		t.Errorf("file %v %v", st, err)
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 1 {
		t.Errorf("the directory holds %d entries, want only session.json (no temporary left)", len(entries))
	}
	tr := transcriptOf(t, dir)
	for _, k := range []string{"protocol", "session_id", "role", "instructions_sha256", "definitions_sha256", "terminal", "input"} {
		if _, ok := tr[k]; !ok {
			t.Errorf("session.json lacks %q", k)
		}
	}
	id := first.first("session.started")["session_id"]
	if tr["session_id"] != id || tr["protocol"] != "kogen-loop/v1" {
		t.Errorf("session.json %v", tr)
	}
	terminal, _ := tr["terminal"].(map[string]any)
	if terminal["call_id"] != "c1" || terminal["name"] != "finish" {
		t.Errorf("terminal %v", tr["terminal"])
	}

	second := runCLI(t, w, f, sessionTask(w, dir, true, map[string]any{"prompt": "feedback: check again"}))
	if second.exit != 0 {
		t.Fatalf("%v %s", second.events, second.stderr)
	}
	started := second.first("session.started")
	if started["resumed"] != true || started["session_id"] != id {
		t.Errorf("session.started %v", started)
	}
	if e := second.first("round.ended"); e["ending"] != "no_call" || e["claim"] != "second answer" {
		t.Errorf("round.ended %v", e)
	}
	// The resumed request is the stored conversation with the feedback answering finish.
	input := f.requests()[1]["input"].([]any)
	last := input[len(input)-1].(map[string]any)
	if last["type"] != "function_call_output" || last["call_id"] != "c1" || last["output"] != "feedback: check again" {
		t.Errorf("last input item %v", last)
	}
	if first := input[0].(map[string]any); first["role"] != "user" || first["content"] != "start" {
		t.Errorf("the opening message was lost: %v", first)
	}
	// The conversation keeps one cache identity across the resume.
	if f.requests()[0]["prompt_cache_key"] != f.requests()[1]["prompt_cache_key"] || f.requests()[0]["prompt_cache_key"] == nil {
		t.Errorf("cache keys %v / %v", f.requests()[0]["prompt_cache_key"], f.requests()[1]["prompt_cache_key"])
	}
	// A third round after the no-call ending appends a user message.
	f3 := newFakeProvider(t, []exchange{{Items: []map[string]any{message("third")}}})
	third := runCLI(t, w, f3, sessionTask(w, dir, true, map[string]any{"prompt": "and now?"}))
	if third.exit != 0 {
		t.Fatalf("%v", third.events)
	}
	input = f3.requests()[0]["input"].([]any)
	if m := input[len(input)-1].(map[string]any); m["role"] != "user" || m["content"] != "and now?" {
		t.Errorf("last input item %v", m)
	}
}

func TestResumeRefusesAMismatchBeforeAnyRequest(t *testing.T) {
	w := newWorld(t).signIn()
	dir := filepath.Join(t.TempDir(), "transcript")
	seed := newFakeProvider(t, []exchange{{Items: []map[string]any{call("c1", "finish", map[string]any{"summary": "x"})}}})
	if r := runCLI(t, w, seed, sessionTask(w, dir, false, map[string]any{"instructions": "be brief"})); r.exit != 0 {
		t.Fatal(r.stderr)
	}
	original, err := os.ReadFile(filepath.Join(dir, "session.json"))
	if err != nil {
		t.Fatal(err)
	}
	role := func(model string) map[string]any {
		return map[string]any{"provider": "chatgpt", "model": model, "effort": "medium", "base_url": ""}
	}
	for name, over := range map[string]map[string]any{
		"other instructions":   {"instructions": "be verbose"},
		"default instructions": {"instructions": ""},
		"other role":           {"instructions": "be brief", "role": role("another-model")},
		"other tools":          {"instructions": "be brief", "tools": []any{"read_file"}},
		"other terminal":       {"instructions": "be brief", "terminal": []any{"done"}},
	} {
		t.Run(name, func(t *testing.T) {
			f := newFakeProvider(t, []exchange{{Items: []map[string]any{message("never")}}})
			r := runCLI(t, w, f, sessionTask(w, dir, true, over))
			expectRefusal(t, r, f, "loop", "session_mismatch", 2)
		})
	}
	t.Run("other protocol in the transcript", func(t *testing.T) {
		var tr map[string]any
		json.Unmarshal(original, &tr)
		tr["protocol"] = "kogen-loop/v0"
		os.WriteFile(filepath.Join(dir, "session.json"), mustJSON(t, tr), 0o600)
		defer os.WriteFile(filepath.Join(dir, "session.json"), original, 0o600)
		f := newFakeProvider(t, nil)
		r := runCLI(t, w, f, sessionTask(w, dir, true, map[string]any{"instructions": "be brief"}))
		expectRefusal(t, r, f, "loop", "session_mismatch", 2)
	})
	t.Run("no transcript", func(t *testing.T) {
		f := newFakeProvider(t, nil)
		r := runCLI(t, w, f, sessionTask(w, filepath.Join(t.TempDir(), "empty"), true, nil))
		expectRefusal(t, r, f, "loop", "session_mismatch", 2)
	})
	t.Run("the matching configuration still resumes", func(t *testing.T) {
		f := newFakeProvider(t, []exchange{{Items: []map[string]any{message("fine")}}})
		r := runCLI(t, w, f, sessionTask(w, dir, true, map[string]any{"instructions": "be brief"}))
		if r.exit != 0 {
			t.Errorf("exit %d: %v", r.exit, r.events)
		}
	})
}

func TestFailedRoundLeavesTheLastCompletedTranscript(t *testing.T) {
	w := newWorld(t).signIn()
	dir := filepath.Join(t.TempDir(), "transcript")
	f := newFakeProvider(t, []exchange{
		{Items: []map[string]any{call("c1", "finish", map[string]any{"summary": "one"})}},
		{Status: 400},
	})
	runCLI(t, w, f, sessionTask(w, dir, false, nil))
	before, _ := os.ReadFile(filepath.Join(dir, "session.json"))
	r := runCLI(t, w, f, sessionTask(w, dir, true, map[string]any{"prompt": "again"}))
	if r.exit != 1 {
		t.Errorf("exit %d", r.exit)
	}
	after, _ := os.ReadFile(filepath.Join(dir, "session.json"))
	if string(before) != string(after) {
		t.Error("a failed round changed the transcript")
	}
}

// ---- commands ----

func runPlain(t *testing.T, args ...string) (string, int) {
	t.Helper()
	w := newWorld(t)
	p := startCLI(t, w, nil, nil, args...)
	code := p.wait()
	return p.stdout.String(), code
}

func TestCapabilitiesNeedNoNetworkOrCredentials(t *testing.T) {
	out, code := runPlain(t, "capabilities", "--json")
	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	var caps map[string]any
	if err := json.Unmarshal([]byte(out), &caps); err != nil {
		t.Fatalf("%v: %q", err, out)
	}
	if strings.Count(strings.TrimSpace(out), "\n") != 0 {
		t.Errorf("capabilities is not one object: %q", out)
	}
	if caps["protocol"] != "kogen-loop/v1" || caps["library"] != "loop/v1" || caps["session_resume"] != "transcript" ||
		caps["usage"] != "provider" || caps["images"] != true || caps["subagents"] != false || caps["compaction"] != false {
		t.Errorf("capabilities %v", caps)
	}
	if got := caps["terminal_default"]; !match([]any{"finish"}, got) {
		t.Errorf("terminal_default %v", got)
	}
	if got := caps["providers"]; !match([]any{"chatgpt", "supergrok", "opencode-go", "anthropic", "openai-compatible"}, got) {
		t.Errorf("providers %v", got)
	}
	if got := caps["tools"]; !match([]any{"read_file", "write_file", "list_files", "search_text", "shell", "view_image", "documentation"}, got) {
		t.Errorf("tools %v", got)
	}
	if got := caps["context_policies"]; !match([]any{"fail_over_budget"}, got) {
		t.Errorf("context_policies %v", got)
	}
}

func TestVersionAndUsage(t *testing.T) {
	if out, code := runPlain(t, "version"); code != 0 || out != "kogen-loop dev\n" {
		t.Errorf("version %q exit %d", out, code)
	}
	for _, args := range [][]string{nil, {"bogus"}, {"capabilities", "--yaml"}, {"version", "extra"}} {
		if out, code := runPlain(t, args...); code != 2 || out != "" {
			t.Errorf("%v: exit %d stdout %q", args, code, out)
		}
	}
	// run without --task is a refused task, still reported as events.
	w := newWorld(t)
	r := startCLI(t, w, nil, nil, "run").result()
	expectRefusal(t, r, nil, "loop", "invalid_task", 2)
}

package conformance

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/KogenAI/kogen-loop/api"
	"github.com/KogenAI/kogen-loop/loop"
)

// runReads runs one Session round of read_file calls (then finish) and returns the tool.result
// fields by call id, the raw tool.call events, and the whole event stream as JSON text.
func runReads(t *testing.T, w *world, calls [][2]any) (results map[string]map[string]any, callEvents []map[string]any, stream string) {
	t.Helper()
	var exchanges []exchange
	for _, c := range calls {
		exchanges = append(exchanges, exchange{Items: []map[string]any{call(c[0].(string), "read_file", c[1].(map[string]any))}})
	}
	exchanges = append(exchanges, exchange{Items: []map[string]any{call("end", "finish", map[string]any{"summary": "done"})}})
	f := newFakeProvider(t, exchanges)
	var events []api.Event
	s, err := loop.NewSession(sessionConfig(w, f, &events))
	if err != nil {
		t.Fatal(err)
	}
	res, err := s.Round(context.Background(), "open")
	if err != nil || res.Ending != loop.EndTerminal {
		t.Fatalf("%v %v", res, err)
	}
	results = map[string]map[string]any{}
	var all strings.Builder
	for _, e := range events {
		b, err := json.Marshal(e)
		if err != nil {
			t.Fatal(err)
		}
		all.Write(b)
		all.WriteByte('\n')
		var fields map[string]any
		if err := json.Unmarshal(b, &fields); err != nil {
			t.Fatal(err)
		}
		switch e.Type {
		case api.EventToolCall:
			callEvents = append(callEvents, fields)
		case api.EventToolResult:
			results[fields["call_id"].(string)] = fields
		}
	}
	return results, callEvents, all.String()
}

func lineFile(count int, row func(i int) string) string {
	var b strings.Builder
	for i := 1; i <= count; i++ {
		b.WriteString(row(i) + "\n")
	}
	return b.String()
}

// field is the JSON text of a tool.result field, "" when it is absent.
func field(r map[string]any, key string) string {
	v, ok := r[key]
	if !ok {
		return ""
	}
	b, _ := json.Marshal(v)
	return string(b)
}

func TestSessionToolResultTiesRecoveringReadsToTheCut(t *testing.T) {
	t.Parallel()
	w := newWorld(t).signIn().seed(map[string]string{
		"big.txt": lineFile(600, func(i int) string { return fmt.Sprintf("big row %d %s secret-big-%d", i, strings.Repeat("b", 30), i) }),
		"other.txt": lineFile(600, func(i int) string {
			return fmt.Sprintf("other row %d %s secret-other-%d", i, strings.Repeat("o", 28), i)
		}),
		"small.txt": lineFile(5, func(i int) string { return fmt.Sprintf("small row %d secret-small-%d", i, i) }),
	})
	abs := filepath.Join(w.root, "big.txt")
	results, callEvents, stream := runReads(t, w, [][2]any{
		{"cut", map[string]any{"path": "big.txt"}},
		{"recover", map[string]any{"path": "./big.txt", "start_line": 100, "end_line": 109}},
		{"straddle", map[string]any{"path": abs, "start_line": 400, "end_line": 405}},
		{"other", map[string]any{"path": "other.txt", "start_line": 100, "end_line": 109}},
		{"before", map[string]any{"path": "big.txt", "start_line": 60, "end_line": 69}},
		{"after", map[string]any{"path": "big.txt", "start_line": 404, "end_line": 410}},
		{"small", map[string]any{"path": "small.txt"}},
		{"small-again", map[string]any{"path": "small.txt", "start_line": 2, "end_line": 3}},
	})
	want := map[string][2]string{ // omitted_lines, recovers
		"cut":      {"[70,403]", ""},
		"recover":  {"", `[{"call_id":"cut","lines":10}]`},
		"straddle": {"", `[{"call_id":"cut","lines":4}]`},
	}
	for id, r := range results {
		w := want[id]
		if got := field(r, "omitted_lines"); got != w[0] {
			t.Errorf("%s: omitted_lines %q, want %q", id, got, w[0])
		}
		if got := field(r, "recovers"); got != w[1] {
			t.Errorf("%s: recovers %q, want %q", id, got, w[1])
		}
		if r["cut"] != (id == "cut") {
			t.Errorf("%s: cut %v", id, r["cut"])
		}
	}
	for _, c := range callEvents {
		if len(c) != 7 { // protocol, seq, time, type, call_id, name, arguments_sha256
			t.Errorf("tool.call fields %v", c)
		}
	}
	for _, leak := range []string{"secret-big-", "big row", "big.txt", "other.txt", "start_line", "end_line", abs} {
		if strings.Contains(stream, leak) {
			t.Errorf("the event stream carries %q", leak)
		}
	}
}

func TestSessionRecoversInEmissionOrderAndBytewiseCuts(t *testing.T) {
	t.Parallel()
	w := newWorld(t).signIn().seed(map[string]string{
		"big.txt":  lineFile(600, func(i int) string { return fmt.Sprintf("big row %d %s", i, strings.Repeat("b", 30)) }),
		"long.txt": lineFile(10, func(i int) string { return strings.Repeat("x", 5000) }),
	})
	results, _, _ := runReads(t, w, [][2]any{
		{"first", map[string]any{"path": "big.txt"}},
		{"second", map[string]any{"path": "big.txt", "start_line": 30}},
		{"inside", map[string]any{"path": "big.txt", "start_line": 200, "end_line": 209}},
		{"long", map[string]any{"path": "long.txt"}},
	})
	first, second := results["first"], results["second"]
	a1, b1 := field(first, "omitted_lines"), field(second, "omitted_lines")
	if a1 == "" || b1 == "" || a1 == b1 {
		t.Fatalf("omitted_lines %q, %q", a1, b1)
	}
	if got := field(first, "recovers"); got != "" {
		t.Errorf("the first cut recovers %q", got)
	}
	if got := field(second, "recovers"); !strings.HasPrefix(got, `[{"call_id":"first","lines":`) {
		t.Errorf("the second cut recovers %q", got)
	}
	if got := field(results["inside"], "recovers"); !strings.HasPrefix(got, `[{"call_id":"first","lines":10},{"call_id":"second","lines":10}]`) {
		t.Errorf("the read inside both omitted ranges recovers %q", got)
	}
	// 10 lines of 5002 bytes: the head holds line 1 in part, the tail lines 9-10 in whole.
	long := results["long"]
	if r := field(long, "omitted_lines"); r != "[1,8]" || long["cut"] != true {
		t.Errorf("a byte-only cut reports omitted_lines %q", r)
	}
}

func TestSessionForgetsCutsAcrossSessions(t *testing.T) {
	t.Parallel()
	w := newWorld(t).signIn().seed(map[string]string{
		"big.txt": lineFile(600, func(i int) string { return fmt.Sprintf("big row %d %s", i, strings.Repeat("b", 30)) }),
	})
	runReads(t, w, [][2]any{{"cut", map[string]any{"path": "big.txt"}}})
	results, _, _ := runReads(t, w, [][2]any{{"again", map[string]any{"path": "big.txt", "start_line": 100, "end_line": 109}}})
	if got := field(results["again"], "recovers"); got != "" {
		t.Errorf("a new Session recovers %q", got)
	}
}

func TestSessionRecoversAcrossRoundsAndCutsOnlyReadFile(t *testing.T) {
	t.Parallel()
	w := newWorld(t).signIn().seed(map[string]string{
		"big.txt": lineFile(600, func(i int) string { return fmt.Sprintf("big row %d %s", i, strings.Repeat("b", 30)) }),
	})
	f := newFakeProvider(t, []exchange{
		{Items: []map[string]any{call("cut", "read_file", map[string]any{"path": "big.txt"})}},
		{Items: []map[string]any{call("end1", "finish", map[string]any{"summary": "x"})}},
		{Items: []map[string]any{
			call("sh", "shell", map[string]any{"command": "seq 1 20000"}),
			call("later", "read_file", map[string]any{"path": "big.txt", "start_line": 200, "end_line": 201}),
		}},
		{Items: []map[string]any{call("end2", "finish", map[string]any{"summary": "x"})}},
	})
	var events []api.Event
	s, err := loop.NewSession(sessionConfig(w, f, &events))
	if err != nil {
		t.Fatal(err)
	}
	for _, text := range []string{"open", "again"} {
		if _, err := s.Round(context.Background(), text); err != nil {
			t.Fatal(err)
		}
	}
	results := map[string]map[string]any{}
	for _, e := range events {
		if e.Type == api.EventToolResult {
			results[fmt.Sprint(e.Fields["call_id"])] = e.Fields
		}
	}
	if sh := results["sh"]; sh["cut"] != true || field(sh, "omitted_lines") != "" || field(sh, "recovers") != "" {
		t.Errorf("a cut shell result carries %v", sh)
	}
	if got := field(results["later"], "recovers"); got != `[{"call_id":"cut","lines":2}]` {
		t.Errorf("a read in a later round recovers %q", got)
	}
}

// resumedRound runs one round of a session in Dir (resuming it unless first) and returns the
// tool.result fields by call id.
func resumedRound(t *testing.T, w *world, dir string, first bool, exchanges []exchange) map[string]map[string]any {
	t.Helper()
	f := newFakeProvider(t, exchanges)
	var events []api.Event
	cfg := sessionConfig(w, f, &events)
	cfg.Dir = dir
	var s *loop.Session
	var err error
	if first {
		s, err = loop.NewSession(cfg)
	} else {
		s, err = loop.ResumeSession(cfg)
	}
	if err != nil {
		t.Fatal(err)
	}
	if res, err := s.Round(context.Background(), "go"); err != nil || res.Ending != loop.EndTerminal {
		t.Fatalf("%v %v", res, err)
	}
	results := map[string]map[string]any{}
	for _, e := range events {
		if e.Type == api.EventToolResult {
			results[fmt.Sprint(e.Fields["call_id"])] = e.Fields
		}
	}
	return results
}

func savedCutReads(t *testing.T, dir string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(dir, "session.json"))
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal(data, &m); err != nil {
		t.Fatal(err)
	}
	return string(m["cut_reads"])
}

func readThenFinish(id string, args map[string]any, end string) []exchange {
	return []exchange{
		{Items: []map[string]any{call(id, "read_file", args)}},
		{Items: []map[string]any{call(end, "finish", map[string]any{"summary": "x"})}},
	}
}

func TestResumedSessionRecoversLinesAnEarlierRoundCutOmitted(t *testing.T) {
	t.Parallel()
	w := newWorld(t).signIn().seed(map[string]string{
		"big.txt": lineFile(600, func(i int) string { return fmt.Sprintf("big row %d %s secret-big-%d", i, strings.Repeat("b", 30), i) }),
		"other.txt": lineFile(600, func(i int) string {
			return fmt.Sprintf("other row %d %s secret-other-%d", i, strings.Repeat("o", 28), i)
		}),
	})
	dir := filepath.Join(t.TempDir(), "session")
	resumedRound(t, w, dir, true, readThenFinish("c-cut", map[string]any{"path": "./big.txt"}, "e1"))
	const one = `{"call_id":"c-cut","file":"big.txt","from":70,"to":403}`
	if got := savedCutReads(t, dir); got != "["+one+"]" {
		t.Fatalf("saved cut_reads %s", got)
	}

	r := resumedRound(t, w, dir, false, []exchange{
		{Items: []map[string]any{
			call("straddle", "read_file", map[string]any{"path": filepath.Join(w.root, "big.txt"), "start_line": 400, "end_line": 405}),
			call("other", "read_file", map[string]any{"path": "other.txt", "start_line": 100, "end_line": 109}),
			call("before", "read_file", map[string]any{"path": "big.txt", "start_line": 60, "end_line": 69}),
			call("after", "read_file", map[string]any{"path": "big.txt", "start_line": 404, "end_line": 410}),
			call("cut2", "read_file", map[string]any{"path": "big.txt"}),
		}},
		{Items: []map[string]any{call("e2", "finish", map[string]any{"summary": "x"})}},
	})
	want := map[string]string{"straddle": `[{"call_id":"c-cut","lines":4}]`}
	for _, id := range []string{"straddle", "other", "before", "after", "cut2"} {
		if got := field(r[id], "recovers"); got != want[id] {
			t.Errorf("%s: recovers %q, want %q", id, got, want[id])
		}
	}
	const two = `{"call_id":"cut2","file":"big.txt","from":70,"to":403}`
	if got := savedCutReads(t, dir); got != "["+one+","+two+"]" {
		t.Fatalf("saved cut_reads after resume %s", got)
	}

	r = resumedRound(t, w, dir, false, readThenFinish("both", map[string]any{"path": "big.txt", "start_line": 400, "end_line": 405}, "e3"))
	if got := field(r["both"], "recovers"); got != `[{"call_id":"c-cut","lines":4},{"call_id":"cut2","lines":4}]` {
		t.Errorf("recovers %q", got)
	}
}

func TestResumedSessionWithoutSavedRecordsRecoversNothing(t *testing.T) {
	t.Parallel()
	w := newWorld(t).signIn().seed(map[string]string{
		"big.txt": lineFile(600, func(i int) string { return fmt.Sprintf("big row %d %s secret-big-%d", i, strings.Repeat("b", 30), i) }),
		"s.txt":   "one\n",
	})
	dir := filepath.Join(t.TempDir(), "session")
	resumedRound(t, w, dir, true, readThenFinish("c-cut", map[string]any{"path": "big.txt"}, "e1"))
	path := filepath.Join(dir, "session.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal(data, &m); err != nil {
		t.Fatal(err)
	}
	delete(m, "cut_reads")
	old, _ := json.Marshal(m)
	if err := os.WriteFile(path, old, 0o600); err != nil {
		t.Fatal(err)
	}
	r := resumedRound(t, w, dir, false, readThenFinish("c-straddle", map[string]any{"path": "big.txt", "start_line": 400, "end_line": 405}, "e2"))
	if got := field(r["c-straddle"], "recovers"); got != "" {
		t.Errorf("recovers %q", got)
	}
	if got := savedCutReads(t, dir); got != "" {
		t.Errorf("a session without records saved cut_reads %s", got)
	}
}

func TestResumeRefusesUndecodableCutReads(t *testing.T) {
	t.Parallel()
	w := newWorld(t).signIn()
	dir := filepath.Join(t.TempDir(), "session")
	resumedRound(t, w, dir, true, []exchange{{Items: []map[string]any{call("end", "finish", map[string]any{"summary": "x"})}}})
	path := filepath.Join(dir, "session.json")
	data, _ := os.ReadFile(path)
	var m map[string]json.RawMessage
	if err := json.Unmarshal(data, &m); err != nil {
		t.Fatal(err)
	}
	m["cut_reads"] = json.RawMessage(`"nope"`)
	bad, _ := json.Marshal(m)
	if err := os.WriteFile(path, bad, 0o600); err != nil {
		t.Fatal(err)
	}
	f := newFakeProvider(t, nil)
	var events []api.Event
	cfg := sessionConfig(w, f, &events)
	cfg.Dir = dir
	_, err := loop.ResumeSession(cfg)
	if err == nil || !strings.Contains(err.Error(), "the session transcript is not valid") {
		t.Fatalf("err %v", err)
	}
}

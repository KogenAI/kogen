package shape

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"kogen/agent"
	"kogen/provider"
	"kogen/sys"
	"kogen/verify"
)

// Ports test/integration/shape_working_context_test.exs.

type windowFx struct {
	t         *testing.T
	root      string
	win       *window
	authority []any
	ev        *Evidence
	progress  []string
	client    *provider.Client
	role      provider.Role
	state     func(head windowRef, count int, snapshot map[string]any, observations []any) map[string]any
}

func newWindowFx(t *testing.T) *windowFx {
	t.Helper()
	root := t.TempDir()
	authority := []any{map[string]any{"role": "user", "content": "exact request Δ\r\n"}}
	ev, err := NewEvidence(root, "fixture")
	if err != nil {
		t.Fatal(err)
	}
	return &windowFx{
		t: t, root: root, authority: authority, ev: ev, client: provider.NewClient(""),
		role: provider.Role{Model: "fixture", Effort: "high"},
		win:  newShapeWindow(root, "fixture", authority),
	}
}

func (f *windowFx) prep() windowPrep {
	return windowPrep{
		root: f.root, ev: f.ev,
		progress: func(line string) { f.progress = append(f.progress, line) },
		render: func(items []any) map[string]any {
			return f.client.Body(provider.Request{Role: f.role, Instructions: "policy", Input: items})
		},
		state: func(head windowRef, count int, snapshot map[string]any, observations []any) map[string]any {
			m := map[string]any{
				"history": map[string]any{"head": head.value(), "count": count}, "manifest": map[string]any{"proposed": []any{}},
				"declared_steps": []any{"features/steps/new.js"}, "inspected": true, "documentation": snapshot,
				"invalid_submissions": 2, "readiness": nil, "assistant_observations": observations,
			}
			if f.state != nil {
				return f.state(head, count, snapshot, observations)
			}
			return m
		},
	}
}

func windowExchange(n int) []any {
	return []any{
		map[string]any{"type": "reasoning", "encrypted_content": fmt.Sprintf("opaque%d", n)},
		map[string]any{"type": "message", "role": "assistant", "phase": "commentary",
			"content": []any{map[string]any{"type": "output_text", "text": fmt.Sprintf("observation %d", n)}}},
		map[string]any{"type": "function_call", "call_id": fmt.Sprintf("a%d", n), "name": "read_file", "arguments": "{}"},
		map[string]any{"type": "function_call", "call_id": fmt.Sprintf("b%d", n), "name": "read_file", "arguments": "{}"},
		map[string]any{"type": "function_call_output", "call_id": fmt.Sprintf("a%d", n), "output": strings.Repeat("x", 190_000)},
		map[string]any{"type": "function_call_output", "call_id": fmt.Sprintf("b%d", n), "output": "second result"},
	}
}

func concatItems(parts ...[]any) []any {
	var out []any
	for _, p := range parts {
		out = append(out, p...)
	}
	return out
}

func windowEvents(t *testing.T, dir string) []map[string]any {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(dir, "events.ndjson"))
	if err != nil {
		t.Fatal(err)
	}
	var out []map[string]any
	for _, line := range strings.Split(strings.TrimSpace(string(b)), "\n") {
		if line == "" {
			continue
		}
		var e map[string]any
		if err := json.Unmarshal([]byte(line), &e); err != nil {
			t.Fatal(err)
		}
		out = append(out, e)
	}
	return out
}

func decodeFile(t *testing.T, path string) map[string]any {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	return m
}

func jsonRoundTrip(t *testing.T, v any) any {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	var out any
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatal(err)
	}
	return out
}

func TestRepeatedWindowsArchiveExactInputAndPreviousHandoffKeepingFullNewestBatch(t *testing.T) {
	f := newWindowFx(t)
	f.win.documentation = []map[string]any{{"result": "unsupported"}}
	input := concatItems(f.authority, windowExchange(1), windowExchange(2), windowExchange(3))
	reduced, err := f.win.prepare(f.prep(), input)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(reduced[0], f.authority[0]) || !reflect.DeepEqual(reduced[len(reduced)-6:], windowExchange(3)) {
		t.Fatalf("the reduced input keeps the authority first and the newest batch whole: %v", reduced)
	}
	if m, _ := agent.Measure(f.prep().render(reduced)); !m.Fits {
		t.Fatal("the reduced request does not fit")
	}
	if len(f.win.history) != 1 {
		t.Fatalf("history %v", f.win.history)
	}
	ref := f.win.history[0]
	archive := decodeFile(t, ref.Path)
	snapshot, _ := archive["documentation"].(map[string]any)
	delete(archive, "documentation")
	want := map[string]any{"version": float64(1), "owner": "shape", "input": jsonRoundTrip(t, input), "previous": nil}
	if !reflect.DeepEqual(archive, want) {
		t.Fatalf("archive keys differ: %v", archive)
	}
	lines, _ := os.ReadFile(snapshot["path"].(string))
	if string(lines) != `{"result":"unsupported"}`+"\n" || snapshot["sha256"] != ContentHash(lines) {
		t.Fatalf("documentation snapshot %q %v", lines, snapshot)
	}
	b, _ := os.ReadFile(ref.Path)
	if ContentHash(b) != ref.SHA256 {
		t.Fatal("the reference does not hash the archive")
	}
	handoff := reduced[1].(map[string]any)["content"].(string)
	if !strings.Contains(handoff, "Local working-window reset") || !strings.Contains(handoff, "observation 1") || strings.Contains(handoff, "unsupported") {
		t.Fatalf("handoff %q", handoff)
	}
	var state map[string]any
	if err := json.Unmarshal([]byte(handoff[strings.LastIndex(handoff, "manifest/state: ")+len("manifest/state: "):]), &state); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(state["history"], map[string]any{"head": map[string]any{"path": ref.Path, "sha256": ref.SHA256}, "count": float64(1)}) ||
		!reflect.DeepEqual(state["documentation"], snapshot) || !strings.Contains(handoff, `"invalid_submissions":2`) {
		t.Fatalf("state %v", state)
	}

	ready := &verify.Ready{Intent: nil, SHA256: "candidate identity", CandidateTree: "tree identity",
		Scenarios: []verify.ScenarioResult{{Name: "missing behavior", Status: "failed"}}}
	f.state = func(head windowRef, count int, snapshot map[string]any, observations []any) map[string]any {
		return map[string]any{
			"history":                map[string]any{"head": head.value(), "count": count},
			"readiness":              map[string]any{"sha256": ready.SHA256, "candidate_tree": ready.CandidateTree, "scenarios": ready.Scenarios},
			"assistant_observations": observations,
		}
	}
	second := concatItems(reduced, windowExchange(4), windowExchange(5))
	next, err := f.win.prepare(f.prep(), second)
	if err != nil {
		t.Fatal(err)
	}
	text := next[1].(map[string]any)["content"].(string)
	if !strings.Contains(text, "candidate identity") || !strings.Contains(text, "missing behavior") {
		t.Fatalf("second handoff %q", text)
	}
	last := f.win.history[len(f.win.history)-1]
	doc := decodeFile(t, last.Path)
	if !reflect.DeepEqual(doc["previous"], map[string]any{"path": ref.Path, "sha256": ref.SHA256}) ||
		!reflect.DeepEqual(doc["input"], jsonRoundTrip(t, second)) {
		t.Fatalf("second archive %v", doc["previous"])
	}
	if len(f.progress) != 2 || !strings.HasPrefix(f.progress[0], "kogen: Shape local working-window reset ") || !strings.Contains(f.progress[0], "custody "+ref.Path) {
		t.Fatalf("progress %v", f.progress)
	}
}

func TestTheResetEventMeasuresTheRequestOfTheNewWindow(t *testing.T) {
	f := newWindowFx(t)
	f.role = provider.Role{Model: "gpt-6.1-sol", Effort: "high"}
	input := concatItems(f.authority, windowExchange(1), windowExchange(2), windowExchange(3))
	reduced, err := f.win.prepare(f.prep(), input)
	if err != nil {
		t.Fatal(err)
	}
	actual, _ := agent.Measure(f.prep().render(reduced))
	var event map[string]any
	for _, e := range windowEvents(t, f.root) {
		if e["event"] == "working_context_reset" {
			event = e
		}
	}
	if event == nil || event["after_bytes"] != float64(actual.RenderedBytes) || event["owner"] != "shape" || event["generation"] != float64(1) ||
		event["input_budget_bytes"] != float64(524288) || event["output_reserve_tokens"] != float64(131072) {
		t.Fatalf("event %v, request %d bytes", event, actual.RenderedBytes)
	}
}

func TestUnsafeAncestorCustodyRefusesBeforeWritingAnUnsentArchive(t *testing.T) {
	f := newWindowFx(t)
	outside := t.TempDir()
	if err := os.MkdirAll(filepath.Join(f.root, ".kogen/local"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(f.root, ".kogen/local/shaping")); err != nil {
		t.Fatal(err)
	}
	// The immediate slug directory exists already, hiding the ancestor symlink from a mkdir-only walk.
	if err := os.Mkdir(filepath.Join(outside, "fixture"), 0o755); err != nil {
		t.Fatal(err)
	}
	input := []any{map[string]any{"role": "user", "content": strings.Repeat("x", 600_000)}}
	f.win = newShapeWindow(f.root, "fixture", input)
	_, err := f.win.prepare(f.prep(), input)
	e, ok := sys.AsError(err)
	if !ok || e.Reason != "context_custody_invalid" {
		t.Fatalf("error %v", err)
	}
	var found []string
	filepath.WalkDir(outside, func(p string, d os.DirEntry, err error) error {
		if err == nil && strings.HasSuffix(p, ".json") {
			found = append(found, p)
		}
		return nil
	})
	if len(found) != 0 {
		t.Fatalf("archives written outside the checkout: %v", found)
	}
}

func TestDamagedCustodyRefusesAnOtherwiseFittingNextRequest(t *testing.T) {
	for _, damage := range []string{"changed", "missing", "symlink", "mode"} {
		t.Run(damage, func(t *testing.T) {
			f := newWindowFx(t)
			input := concatItems(f.authority, windowExchange(1), windowExchange(2), windowExchange(3))
			reduced, err := f.win.prepare(f.prep(), input)
			if err != nil {
				t.Fatal(err)
			}
			path := f.win.history[0].Path
			switch damage {
			case "changed":
				err = os.WriteFile(path, []byte("changed"), 0o600)
			case "missing":
				err = os.Remove(path)
			case "symlink":
				if err = os.Rename(path, path+".original"); err == nil {
					err = os.Symlink(path+".original", path)
				}
			case "mode":
				err = os.Chmod(path, 0o644)
			}
			if err != nil {
				t.Fatal(err)
			}
			_, err = f.win.prepare(f.prep(), reduced)
			if e, ok := sys.AsError(err); !ok || e.Reason != "context_custody_invalid" || !strings.Contains(e.Detail, "Shape working-context custody missing, changed or unsafe: "+path) {
				t.Fatalf("error %v", err)
			}
		})
	}
}

func TestADamagedDocumentationSnapshotIsDamagedCustody(t *testing.T) {
	f := newWindowFx(t)
	f.win.documentation = []map[string]any{{"status": "retrieved"}}
	input := concatItems(f.authority, windowExchange(1), windowExchange(2), windowExchange(3))
	if _, err := f.win.prepare(f.prep(), input); err != nil {
		t.Fatal(err)
	}
	archive := decodeFile(t, f.win.history[0].Path)
	snapshot := archive["documentation"].(map[string]any)["path"].(string)
	if err := os.WriteFile(snapshot, []byte("damage"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := f.win.validate(f.root); err == nil {
		t.Fatal("a damaged snapshot passed custody")
	}
}

func TestIrreducibleAuthorityIsRetainedExactlyUnsent(t *testing.T) {
	f := newWindowFx(t)
	input := []any{map[string]any{"role": "user", "content": strings.Repeat("x", 600_000)}}
	f.win = newShapeWindow(f.root, "huge", input)
	_, err := f.win.prepare(f.prep(), input)
	e, ok := sys.AsError(err)
	if !ok || e.Reason != "context_budget_exceeded" || !strings.Contains(e.Detail, "fresh identical retry is not recovery") ||
		!strings.Contains(e.Detail, "Shape has no persistent resume.") {
		t.Fatalf("error %v", err)
	}
	matches, _ := filepath.Glob(filepath.Join(f.win.dir, "*.json"))
	if len(matches) != 1 || !reflect.DeepEqual(decodeFile(t, matches[0])["input"], jsonRoundTrip(t, input)) {
		t.Fatalf("archives %v", matches)
	}
	var stop map[string]any
	for _, ev := range windowEvents(t, f.root) {
		if ev["event"] == "working_context_stop" {
			stop = ev
		}
	}
	if stop == nil || stop["owner"] != "shape" || stop["measured_bytes"] == nil {
		t.Fatalf("stop event %v", stop)
	}
}

func TestARefineWindowLivesInTheRunEvidenceAndNamesItsOwner(t *testing.T) {
	root := t.TempDir()
	evidence := filepath.Join(root, ".kogen/local/refinements/abc")
	if err := os.MkdirAll(evidence, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(evidence, 0o700); err != nil {
		t.Fatal(err)
	}
	ev, err := NewEvidence(evidence, "fixture")
	if err != nil {
		t.Fatal(err)
	}
	input := []any{map[string]any{"role": "user", "content": strings.Repeat("x", 600_000)}}
	w := newRefineWindow(evidence, input)
	client := provider.NewClient("")
	var lines []string
	_, err = w.prepare(windowPrep{
		root: root, ev: ev, progress: func(l string) { lines = append(lines, l) },
		render: func(items []any) map[string]any {
			return client.Body(provider.Request{Role: provider.Role{Model: "fixture", Effort: "high"}, Instructions: "policy", Input: items})
		},
		state: func(windowRef, int, map[string]any, []any) map[string]any { return map[string]any{} },
	}, input)
	e, ok := sys.AsError(err)
	if !ok || e.Reason != "context_budget_exceeded" || !strings.HasPrefix(e.Detail, "Refine complete next request ") ||
		!strings.HasSuffix(e.Detail, "Refine has no persistent resume.") {
		t.Fatalf("error %v", err)
	}
	if filepath.Dir(w.dir) != evidence {
		t.Fatalf("window folder %s", w.dir)
	}
	if doc := decodeFile(t, filepath.Join(w.dir, "1.json")); doc["owner"] != "refine" {
		t.Fatalf("archive owner %v", doc["owner"])
	}
}

package build

import (
	"encoding/json"
	"net/http"
	"os"
	"strings"
	"testing"
)

// Observation only: installed package tests supply the real Build/fake-provider fixture.
// This file is mounted as a test with go -overlay; it changes no production source.
func TestK11ReviewUnreadObservation(t *testing.T) {
	var cfg struct {
		Steps []string `json:"steps"`
	}
	raw, err := os.ReadFile(os.Getenv("KOGEN_K11_INPUT"))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(raw, &cfg); err != nil {
		t.Fatal(err)
	}
	e := newEnv(t)
	f := e.prov
	f.then(f.calls("write_file", map[string]any{"path": "app.txt", "content": bigFile()}, "finish", map[string]any{"summary": "done"}))
	partsOf := func() []string { return catalogParts(reviewCatalog(f.t, f.reviewRequests()[0])) }
	// The fake provider assigns the call id when a call is constructed, so every
	// "changes" step builds its own call with its own call_id.
	changes := func() handler {
		return f.calls("submit_review", map[string]any{"verdict": "changes", "findings": []any{
			finding("blocking", "the remaining parts were not delivered"),
		}})
	}
	// readAll reads every pinned part in batches, then submits the verdict; it keeps its place.
	readAll := func(verdict string) handler {
		var parts []string
		next := 0
		return func(w http.ResponseWriter, r *http.Request) {
			if parts == nil {
				parts = partsOf()
			}
			if next >= len(parts) {
				if verdict == "approve" {
					submit(f, "approve")(w, r)
				} else {
					submit(f, "changes", finding("blocking", "real defect"))(w, r)
				}
				return
			}
			var pairs []any
			for _, p := range parts[next:min(next+15, len(parts))] {
				pairs = append(pairs, "read_file", map[string]any{"path": p})
			}
			next += 15
			f.calls(pairs...)(w, r)
		}
	}
	for _, step := range cfg.Steps {
		switch step {
		case "changes":
			f.then(changes())
		case "changes-forever":
			for i := 0; i < 40; i++ {
				f.then(changes())
			}
		case "read-last":
			f.then(func(w http.ResponseWriter, r *http.Request) {
				parts := partsOf()
				f.calls("read_file", map[string]any{"path": parts[len(parts)-1]})(w, r)
			})
		case "read-all-approve", "read-all-changes":
			shared := readAll(strings.TrimPrefix(step, "read-all-"))
			for i := 0; i < 30; i++ {
				f.then(shared)
			}
		default:
			t.Fatalf("unknown step %q", step)
		}
	}
	start := e.head()
	a := e.reviewed()
	reqs := f.reviewRequests()
	feedback := []string{}
	// Working-window resets archive older exchanges, so unread-parts feedback is
	// collected across every review request and de-duplicated by call_id.
	seen := map[string]bool{}
	for _, req := range reqs {
		items := requestInput(req)
		ids := map[string]bool{}
		for _, item := range items {
			m, _ := item.(map[string]any)
			if m["type"] == "function_call" && m["name"] == "submit_review" {
				id, _ := m["call_id"].(string)
				ids[id] = true
			}
		}
		for _, item := range items {
			m, _ := item.(map[string]any)
			id, _ := m["call_id"].(string)
			if m["type"] == "function_call_output" && ids[id] && !seen[id] {
				text, ok := m["output"].(string)
				if !ok {
					t.Fatal("submit_review output was not text")
				}
				seen[id] = true
				feedback = append(feedback, text)
			}
		}
	}
	row := map[string]any{
		"exit": a.exit, "requests": len(reqs), "feedback": feedback, "head_changed": e.head() != start,
		"output": a.shown(), "outcome": e.result(e.onlyRun())["outcome"],
	}
	data, err := json.Marshal(row)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(os.Getenv("KOGEN_K11_OUTPUT"), data, 0o600); err != nil {
		t.Fatal(err)
	}
}

package build

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Observation only: installed package tests supply the real Build/fake-provider fixture.
// This file is mounted as a test with go -overlay; it changes no production source.
func TestReviewEfficiencyObservation(t *testing.T) {
	var cfg struct {
		Mode  string           `json:"mode"`
		Cases []map[string]any `json:"cases"`
		Twice bool             `json:"twice"`
	}
	raw, err := os.ReadFile(os.Getenv("KOGEN_REVIEW_EFFICIENCY_INPUT"))
	if err != nil {
		t.Fatal(err)
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&cfg); err != nil {
		t.Fatal(err)
	}
	rows := []map[string]any{}
	for _, args := range cfg.Cases {
		if cfg.Mode == "direct" {
			root := t.TempDir()
			if err := os.WriteFile(filepath.Join(root, "app.txt"), []byte("fixture\n"), 0o600); err != nil {
				t.Fatal(err)
			}
			r := &reviewRun{b: &Attempt{Root: root}}
			v, probs, err := r.validate(args, nil)
			failure := ""
			if err != nil {
				failure = err.Error()
			}
			rows = append(rows, map[string]any{"accepted": v != nil, "problems": strings.Join(probs, "\n"), "error": failure})
			continue
		}
		e := newEnv(t)
		// writeFile in the shared fixture uses creation modes, which a 077 umask masks.
		// This acceptance owns only the external fixture executable; set its final mode.
		if err := os.Chmod(filepath.Join(e.aux, "accept.sh"), 0o700); err != nil {
			t.Fatal(err)
		}
		f := e.prov
		f.then(landScript(f)...)
		f.then(f.calls("submit_review", args))
		if cfg.Twice {
			f.then(f.calls("submit_review", args))
		} else {
			f.then(submit(f, "approve"))
		}
		start := e.head()
		a := e.reviewed()
		reqs := f.reviewRequests()
		feedback := []string{}
		instructions := ""
		if len(reqs) > 0 {
			instructions = requestInstructions(reqs[0])
		}
		if len(reqs) > 1 {
			items := requestInput(reqs[1])
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
				if m["type"] == "function_call_output" && ids[id] {
					text, ok := m["output"].(string)
					if !ok {
						t.Fatal("submit_review output was not text")
					}
					feedback = append(feedback, text)
				}
			}
		}
		rows = append(rows, map[string]any{
			"exit": a.exit, "requests": len(reqs), "feedback": feedback,
			"instructions": instructions, "head_changed": e.head() != start,
			"output": a.shown(), "outcome": e.result(e.onlyRun())["outcome"],
		})
	}
	data, err := json.Marshal(rows)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(os.Getenv("KOGEN_REVIEW_EFFICIENCY_OUTPUT"), data, 0o600); err != nil {
		t.Fatal(err)
	}
}

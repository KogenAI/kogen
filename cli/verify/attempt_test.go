package verify

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	"kogen-loop/sys"
)

func TestAttemptBoundsEachStepAndKeepsEvidence(t *testing.T) {
	root := t.TempDir()
	s := sys.NewWith(os.Environ(), root)
	a := NewAttempt(root, "demo", nil)
	a.timeout = time.Second
	ctx := a.Into(context.Background())

	// A step within its bound passes; the bound is per step, not shared.
	for _, name := range []string{"setup-1", "setup-2"} {
		res, err := run(withStep(ctx, name, "setup"), s, Tools{}, "sleep 0.7; echo ok", root, nil)
		if err != nil || res.Status != 0 {
			t.Fatalf("%s: %v %+v", name, err, res)
		}
	}
	a.Plan("setup-1", "setup-2", "setup-3", "acceptance")
	_, err := run(withStep(ctx, "setup-3", "setup"), s, Tools{}, "echo started-then-blocked >&2; sleep 30 & wait", root, nil)
	refusal := a.Refuse(err)
	e, ok := sys.AsError(refusal)
	if !ok || e.Reason != "step_timeout" {
		t.Fatalf("error = %v, want a step timeout refusal", refusal)
	}
	text := e.Render()
	for _, want := range []string{"setup-3", "timed out after 1.", "started-then-blocked", "setup-1: passed in 0.", "Not run: acceptance", "names no cause", "Evidence: "} {
		if !strings.Contains(text, want) {
			t.Errorf("the refusal lacks %q:\n%s", want, text)
		}
	}
	if strings.Contains(text, "git add") {
		t.Errorf("the refusal blames Git:\n%s", text)
	}
	path := text[strings.LastIndex(text, "Evidence: ")+len("Evidence: "):]
	raw, readErr := os.ReadFile(strings.TrimSpace(path))
	if readErr != nil {
		t.Fatal(readErr)
	}
	var rec struct {
		Outcome string `json:"outcome"`
		Steps   []struct {
			Name     string `json:"name"`
			TimedOut bool   `json:"timed_out"`
		} `json:"steps"`
		NotRun []string `json:"not_run"`
	}
	if err := json.Unmarshal(raw, &rec); err != nil || rec.Outcome != "refused" || len(rec.Steps) != 3 || !rec.Steps[2].TimedOut || rec.Steps[0].TimedOut {
		t.Errorf("evidence = %v %+v", err, rec)
	}
	if len(rec.NotRun) != 1 || rec.NotRun[0] != "acceptance" {
		t.Errorf("not_run = %v", rec.NotRun)
	}
}

func TestAttemptRefusalPassesInterruptsAndNonRefusalsThrough(t *testing.T) {
	a := NewAttempt(t.TempDir(), "demo", nil)
	for _, err := range []error{context.Canceled, &sys.Interrupted{Signal: "SIGINT"}, os.ErrNotExist} {
		if got := a.Refuse(err); got != err {
			t.Errorf("Refuse(%v) = %v, want it unchanged", err, got)
		}
	}
	// A refusal before any command ran (a lint error) is not an attempt's failure.
	lint := sys.Fail("intent", "lint", "bad", 1)
	if got := a.Refuse(lint); got != error(lint) {
		t.Errorf("a refusal before any step = %v", got)
	}
}

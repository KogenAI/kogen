package build

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"kogen/project"
)

// Observation only: it mounts as a test with go -overlay and changes no production source. It
// runs the real native Build against the scripted fake provider (no live model call) and a
// scripted acceptance command over three scenarios; nothing sleeps.

const kbesFeature = "Feature: Early stop fixture\n  Scenario: First\n    Then the acceptance check passes\n  Scenario: Second\n    Then the acceptance check passes\n  Scenario: Third\n    Then the acceptance check passes\n"

// kbesReport is the acceptance report of the fixture's three scenarios; passed says which pass.
func kbesReport(t *testing.T, feature string, passed func(i int) bool) string {
	t.Helper()
	scenarios, err := project.ParseGherkin(kbesFeature)
	if err != nil {
		t.Fatal(err)
	}
	events := []obj{documentMessage(feature, scenarios)}
	for i, s := range scenarios {
		status := "FAILED"
		if passed(i) {
			status = "PASSED"
		}
		events = append(events, caseMessages(s, i+1, feature, statuses(repeat(status, len(s.Steps))...))...)
	}
	var lines []string
	for _, ev := range events {
		b, err := encodeJSON(ev)
		if err != nil {
			t.Fatal(err)
		}
		lines = append(lines, string(b))
	}
	return strings.Join(lines, "\n") + "\n"
}

// kbesLastInput is the text the builder received last in a request: a user message or the
// output that answers its finish call.
func kbesLastInput(req map[string]any) string {
	items, _ := req["input"].([]any)
	if len(items) == 0 {
		return ""
	}
	it, _ := items[len(items)-1].(map[string]any)
	if s, ok := it["output"].(string); ok {
		return s
	}
	switch c := it["content"].(type) {
	case string:
		return c
	case []any:
		var parts []string
		for _, p := range c {
			if m, ok := p.(map[string]any); ok {
				if s, ok := m["text"].(string); ok {
					parts = append(parts, s)
				}
			}
		}
		return strings.Join(parts, "\n")
	}
	return ""
}

func TestKBuildEarlyStopObservation(t *testing.T) {
	mode := os.Getenv("KOGEN_KBES_MODE")
	out := map[string]any{"mode": mode}
	var e *env
	switch mode {
	case "partial-then-repair", "partial-stuck":
		// app.txt "one": only the first scenario passes; "all": every scenario passes.
		e = newEnv(t)
		feature := project.FeaturePath(testSlug)
		writeFile(t, filepath.Join(e.root, feature), kbesFeature, 0o644)
		e.approve()
		all := filepath.Join(e.aux, "all.ndjson")
		one := filepath.Join(e.aux, "one.ndjson")
		none := filepath.Join(e.aux, "none.ndjson")
		writeFile(t, all, kbesReport(t, feature, func(int) bool { return true }), 0o644)
		writeFile(t, one, kbesReport(t, feature, func(i int) bool { return i == 0 }), 0o644)
		writeFile(t, none, kbesReport(t, feature, func(int) bool { return false }), 0o644)
		writeFile(t, filepath.Join(e.aux, "accept.sh"), "#!/bin/sh\n"+
			"if grep -qx all app.txt; then cp '"+all+"' \"$KOGEN_ACCEPTANCE_REPORT\"; exit 0; fi\n"+
			"if grep -qx one app.txt; then cp '"+one+"' \"$KOGEN_ACCEPTANCE_REPORT\"; echo partial-red; exit 1; fi\n"+
			"cp '"+none+"' \"$KOGEN_ACCEPTANCE_REPORT\"; echo red; exit 1\n", 0o755)
	case "checks-only":
		// Acceptance stays green; a configured check fails once app.txt is "one".
		e = newEnv(t, func(c *project.Config) {
			c.Checks = []project.Check{{Name: "done", Run: "! grep -qx one app.txt"}}
		})
	default:
		t.Fatalf("unknown mode %q", mode)
	}
	start := e.head()
	f := e.prov
	f.then(f.calls("write_file", map[string]any{"path": "app.txt", "content": "one\n"}, "finish", map[string]any{"summary": "first"}))
	switch mode {
	case "partial-then-repair":
		f.then(says("I wrote the test for the first scenario; the round is complete."))
		f.then(f.calls("write_file", map[string]any{"path": "app.txt", "content": "all\n"}, "finish", map[string]any{"summary": "the rest"}))
		f.then(sayings(4)...)
	default:
		f.then(sayings(12)...)
	}
	a := e.build()
	out["exit"] = a.exit
	out["stdout"] = a.out.String()
	reqs := f.requests()
	out["requests"] = len(reqs)
	inputs := []string{}
	for i, r := range reqs {
		if i > 0 { // the first request is the brief
			inputs = append(inputs, kbesLastInput(r))
		}
	}
	out["inputs"] = inputs
	id := e.onlyRun()
	res := e.result(id)
	out["outcome"] = res["outcome"]
	out["passes"] = res["passes"]
	notices := eventsNamed(e.events(id), "missing_items_notice")
	if notices == nil {
		notices = []map[string]any{}
	}
	out["notices"] = notices
	out["head_same"] = e.head() == start
	out["candidate"] = e.read("app.txt")
	raw, err := json.Marshal(out)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(os.Getenv("KOGEN_KBES_OUTPUT"), raw, 0o600); err != nil {
		t.Fatal(err)
	}
}

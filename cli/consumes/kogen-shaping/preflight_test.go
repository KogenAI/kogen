package consumes

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"

	"github.com/KogenAI/kogen-shaping/shape"
)

// preflight calls shape.Preflight as kogen's cli/facts.go does for `kogen intent preflight`:
// with the checkout root, the slug, the JSON flag and the checkout facts it discovered.
func (f *fx) preflight(jsonMode bool, checkout map[string]any) (int, string, error) {
	f.t.Helper()
	s, out := f.session()
	exit, err := shape.Preflight(s.Context(), s, shape.PreflightInput{Project: f.root, Slug: slug, JSON: jsonMode, Checkout: checkout})
	return exit, out.String(), err
}

// TestPreflightJSONShowsTheCheckoutAndTheBlockers: with JSON, Preflight prints one JSON line with
// the checkout facts kogen passed, verbatim, and the observations: exit 1 and the approval
// blocker before the Intent is approved, exit 0 and no blocker after.
func TestPreflightJSONShowsTheCheckoutAndTheBlockers(t *testing.T) {
	f := newFx(t, false)
	f.addIntent()
	checkout := map[string]any{"root": f.root, "git_dir": f.root + "/.git", "id": "0123456789abcdef"}

	doc := func(want int) map[string]any {
		t.Helper()
		exit, out, err := f.preflight(true, checkout)
		var doc map[string]any
		if err != nil || exit != want || strings.Count(out, "\n") != 1 || json.Unmarshal([]byte(out), &doc) != nil {
			t.Fatalf("exit %d (want %d), err %v, output %q", exit, want, err, out)
		}
		if doc["schema_version"] != float64(1) || doc["kind"] != "preflight" || doc["error"] != nil || !reflect.DeepEqual(doc["checkout"], map[string]any{"root": f.root, "git_dir": f.root + "/.git", "id": "0123456789abcdef"}) {
			t.Fatalf("document = %v", doc)
		}
		return doc["data"].(map[string]any)
	}

	data := doc(1)
	blockers := data["blockers"].([]any)
	if data["slug"] != slug || data["ready"] != false {
		t.Fatalf("data = %v", data)
	}
	found := false
	for _, blocker := range blockers {
		b := blocker.(map[string]any)
		if b["class"] == "intent" && b["reason"] == "approval_changed" {
			found = true
		}
	}
	if !found {
		t.Fatalf("approval blocker missing: %v", blockers)
	}

	f.approve(f.card(), "")
	data = doc(0)
	if data["ready"] != true || len(data["blockers"].([]any)) != 0 {
		t.Fatalf("data after approval = %v", data)
	}
	var names []string
	for _, c := range data["checks"].([]any) {
		c := c.(map[string]any)
		if c["status"] != "passed" {
			t.Fatalf("check %v", c)
		}
		names = append(names, c["name"].(string))
	}
	if !reflect.DeepEqual(names, []string{"configuration", "package", "approval", "cleanliness", "conflict"}) {
		t.Fatalf("checks = %v", names)
	}
}

// TestPreflightTextReportsTheState: without JSON, Preflight prints `preflight <slug>: <state>`
// and one line per check, with exit 1 while blocked and 0 when ready.
func TestPreflightTextReportsTheState(t *testing.T) {
	f := newFx(t, false)
	f.addIntent()
	exit, out, err := f.preflight(false, nil)
	if err != nil || exit != 1 || !strings.HasPrefix(out, "preflight fixture: blocked\n  configuration: passed\n  package: passed\n  approval: blocked\n") ||
		!strings.Contains(out, "  intent/approval_changed: exact current approval is absent or changed\n") {
		t.Fatalf("exit %d, err %v\n%s", exit, err, out)
	}
	f.approve(f.card(), "")
	exit, out, err = f.preflight(false, nil)
	if err != nil || exit != 0 || !strings.HasPrefix(out, "preflight fixture: ready (observations only)\n  configuration: passed\n") {
		t.Fatalf("exit %d, err %v\n%s", exit, err, out)
	}
}

// TestPreflightUnreadableConfigurationIsExit3: a configuration that cannot be read is printed
// and is exit 3 with a nil error, which kogen returns as its exit code.
func TestPreflightUnreadableConfigurationIsExit3(t *testing.T) {
	f := newFx(t, false)
	f.addIntent()
	f.configure("version: 2\n")
	exit, out, err := f.preflight(false, nil)
	if err != nil || exit != 3 || !strings.HasPrefix(out, "preflight: ") {
		t.Fatalf("exit %d, err %v, output %q", exit, err, out)
	}
	exit, out, err = f.preflight(true, map[string]any{"id": "x"})
	var doc map[string]any
	if err != nil || exit != 3 || json.Unmarshal([]byte(out), &doc) != nil || doc["data"] != nil || doc["error"] == nil {
		t.Fatalf("exit %d, err %v, output %q", exit, err, out)
	}
}

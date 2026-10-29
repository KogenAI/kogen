package build

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"kogen/agent"
)

// firstReviewWire is the first independent-review request of a run exactly as the provider
// received it, with only the values that differ between runs replaced: the temporary folders,
// the start HEAD and the conversation's cache identity.
func (e *env) firstReviewWire(start string) string {
	e.t.Helper()
	reqs, raw := e.prov.requests(), e.prov.rawRequests()
	for i, req := range reqs {
		if requestInstructions(req) != agent.Prompt(agent.Reviewer) {
			continue
		}
		text := string(raw[i])
		for from, to := range map[string]string{e.root: "<ROOT>", e.aux: "<AUX>", e.home: "<HOME>", start: "<HEAD>", short(start): "<HEAD8>"} {
			text = strings.ReplaceAll(text, from, to)
		}
		return regexp.MustCompile(`"prompt_cache_key":"[^"]*"`).ReplaceAllString(text, `"prompt_cache_key":"<CACHE>"`)
	}
	e.t.Fatal("no review request")
	return ""
}

func wireFixture(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", "reviewretry", name))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// TestKReviewRetryUnchangedValidRequests: a review whose first verdict is valid sends exactly
// the requests it always sent (baseline wire fixtures recorded before the retry/forcing change)
// and ends as it always ended, with no retry, no reminder and no forcing field.
func TestKReviewRetryUnchangedValidRequests(t *testing.T) {
	t.Run("approve lands", func(t *testing.T) {
		t.Parallel()
		e := newEnv(t)
		f := e.prov
		f.then(landScript(f)...)
		f.then(submit(f, "approve", finding("note", "harmless preference")))
		start := e.head()
		a := e.reviewed()
		eq(t, "exit", a.exit, 0)
		eq(t, "commits", e.gitOut("rev-list", "--count", start+"..HEAD"), "1")
		id := e.onlyRun()
		eq(t, "review requests", len(f.reviewRequests()), 1)
		eq(t, "reviews", e.result(id)["reviews"], any(float64(1)))
		wire := e.firstReviewWire(start)
		eq(t, "approve request bytes", wire, wireFixture(t, "approve.wire.json"))
		lacks(t, "wire", wire, `"name":"submit_review"}`)
		contains(t, "wire", wire, `"tool_choice":"auto"`)
		// Independence, material and validation are the original ones.
		req := f.reviewRequests()[0]
		eq(t, "input items", len(requestInput(req)), 1)
		var names []string
		for _, tool := range req["tools"].([]any) {
			names = append(names, tool.(map[string]any)["name"].(string))
		}
		eq(t, "tools", names, []string{"read_file", "view_image", "list_files", "search_text", "write_file", "shell", "submit_review"})
		lacks(t, "wire", wire, "function_call")
		for _, name := range []string{"review_retry", "review_only", "review_tool_choice", "review_allowance"} {
			eq(t, name+" events", len(eventsNamed(e.events(id), name)), 0)
		}
		eq(t, "review events", len(eventsNamed(e.events(id), "review")), 1)
	})

	t.Run("changes is a substantive blocker, not an invalid review", func(t *testing.T) {
		t.Parallel()
		e := newEnv(t)
		f := e.prov
		f.then(landScript(f)...)
		f.then(submit(f, "changes", finding("blocking", "app.txt is wrong")))
		start := e.head()
		a := e.reviewed()
		wantStop(t, a, "candidate/review_blocked")
		eq(t, "head", e.head(), start)
		id := e.onlyRun()
		eq(t, "review requests", len(f.reviewRequests()), 1)
		eq(t, "outcome", e.result(id)["outcome"], any("review_blocked"))
		eq(t, "request bytes", e.firstReviewWire(start), wireFixture(t, "changes.wire.json"))
		for _, name := range []string{"review_retry", "review_only", "review_tool_choice", "review_allowance"} {
			eq(t, name+" events", len(eventsNamed(e.events(id), name)), 0)
		}
		// The stop is the one a blocker always had: nothing offers a review-only continuation.
		cont, _ := sessionOfRun(t, e, id)
		if cont["stage"] == StageReviewOnly {
			t.Fatal("a blocker produced a review-only checkpoint")
		}
	})
}

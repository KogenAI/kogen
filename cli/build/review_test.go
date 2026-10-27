package build

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"
	"time"

	"kogen/agent"
	"kogen/project"
)

// The real independent reviewer against a scripted provider: the builder's response is the
// first scripted handler, the reviewer's follow.

func useRealReviewer(in *Input)               { in.Reviewer = nil }
func useRealReviewerOnResume(in *ResumeInput) { in.Reviewer = nil }

func sleepBriefly() { time.Sleep(50 * time.Millisecond) }

func (e *env) reviewed(mutate ...func(*Input)) *attempt {
	e.t.Helper()
	return e.build(append([]func(*Input){useRealReviewer}, mutate...)...)
}

func (e *env) resumeReviewed(id string) *attempt {
	e.t.Helper()
	return e.resume(id, useRealReviewerOnResume)
}

func (e *env) startReviewed() (*attempt, <-chan struct{}) {
	e.t.Helper()
	return e.start(useRealReviewer)
}

// reviewRequests are the provider requests of the reviewer, in order.
func (f *fakeProvider) reviewRequests() []map[string]any {
	var out []map[string]any
	for _, req := range f.requests() {
		if requestInstructions(req) == agent.Prompt(agent.Reviewer) {
			out = append(out, req)
		}
	}
	return out
}

// requestInstructions are the model's instructions: the request's own, or, for a model with
// prompt-cache support, the developer message that opens the input.
func requestInstructions(req map[string]any) string {
	if s, ok := req["instructions"].(string); ok {
		return s
	}
	items, _ := req["input"].([]any)
	if len(items) == 0 {
		return ""
	}
	dev, _ := items[0].(map[string]any)
	blocks, _ := dev["content"].([]any)
	if len(blocks) == 0 {
		return ""
	}
	text, _ := blocks[0].(map[string]any)["text"].(string)
	return text
}

// requestInput is the conversation of a request, without the developer message.
func requestInput(req map[string]any) []any {
	items, _ := req["input"].([]any)
	if _, ok := req["instructions"]; !ok && len(items) > 0 {
		return items[1:]
	}
	return items
}

func requestText(req map[string]any) string {
	b, _ := json.Marshal(requestInput(req))
	return string(b)
}

func submit(f *fakeProvider, verdict string, findings ...map[string]any) handler {
	list := []any{}
	for _, x := range findings {
		list = append(list, x)
	}
	return f.calls("submit_review", map[string]any{"verdict": verdict, "findings": list})
}

func finding(severity, message string) map[string]any {
	return map[string]any{"path": "app.txt", "line": 1, "severity": severity, "message": message}
}

func writeApp(content string) []any {
	return []any{"write_file", map[string]any{"path": "app.txt", "content": content}}
}

func sessionOfRun(t *testing.T, e *env, id string) (map[string]any, map[string]any) {
	t.Helper()
	_, state := e.checkpoint(id)
	cont := state["continuation"].(map[string]any)
	var session map[string]any
	if raw, ok := cont["review"].(map[string]any); ok {
		session = raw
	}
	return cont, session
}

func TestTheReviewerApprovesUnchangedCodeWithoutRepairs(t *testing.T) {
	t.Parallel()
	// ExUnit: test/integration/release_behavior_test.exs: REV-4/REV-5 retries one invalid review verdict and lands after approval (approval of unchanged code)
	// ExUnit: .kogen/intents/reviewer-style-discipline: unchanged correct-code approval succeeds without an edit quota or preference blockers
	e := newEnv(t)
	f := e.prov
	f.then(landScript(f)...)
	f.then(submit(f, "approve", finding("note", "harmless preference")))
	start := e.head()
	a := e.reviewed()
	if a.exit != 0 || a.err != nil {
		t.Fatalf("exit %d err %v\n%s", a.exit, a.err, a.shown())
	}
	id := e.onlyRun()
	contains(t, "stdout", a.out.String(), "  review: approved, 1 note(s)\n  note: app.txt:1: harmless preference\n  repairs: 0 · tokens: 4 ")
	eq(t, "commits", e.gitOut("rev-list", "--count", start+"..HEAD"), "1")
	eq(t, "committed", e.gitOut("show", "HEAD:app.txt"), "candidate")

	reqs := f.reviewRequests()
	if len(reqs) != 1 {
		t.Fatalf("%d review requests", len(reqs))
	}
	req := reqs[0]
	if got := fmt.Sprintf("%x", sha256.Sum256([]byte(requestInstructions(req)))); got != "1ab7ff81c6b94254ac71958230859fd9c76ffc15baa25ad2552017cbd11cceb9" {
		t.Fatalf("emitted reviewer prompt hash = %s", got)
	}
	// A fresh conversation: one opening message, the reviewer's tools, no builder replay.
	input := requestInput(req)
	if len(input) != 1 {
		t.Fatalf("%d input items", len(input))
	}
	var names []string
	for _, tool := range req["tools"].([]any) {
		names = append(names, tool.(map[string]any)["name"].(string))
	}
	if !slices.Equal(names, []string{"read_file", "view_image", "list_files", "search_text", "write_file", "shell", "submit_review"}) {
		t.Fatalf("tools %v", names)
	}
	contains(t, "instructions", requestInstructions(req), "Delegate mechanically enforceable formatting and style to the existing configured formatters")
	contains(t, "instructions", requestInstructions(req), "Approving unchanged correct code is a successful outcome.")
	blocks := input[0].(map[string]any)["content"].([]any)
	authority := blocks[0].(map[string]any)["text"].(string)
	source := blocks[1].(map[string]any)["text"].(string)
	for _, part := range []string{
		"# Intent\n\n# Preserve the fixture\n", "# acceptance.feature\n\nFeature: Integration fixture\n", "# Project instructions (README.md)\n\n# Fixture project\n",
		"Source provenance: ", "# Testing rules (docs/testing-rules.md)\n\n", "# Protected paths and configured commands\n\nThe approved baseline cannot change: ",
		"Acceptance: ",
	} {
		contains(t, "authority", authority, part)
	}
	for _, part := range []string{
		"# Check results of the final pass\n\nacceptance: passed (2 scenarios)\nmodel: not applicable\n\n# Diff of existing/deleted paths against start HEAD " + short(start),
		"-baseline\n+candidate\n", "# Full text of every changed or added file\n\nNewly added files appear here once, with their mode, instead of being repeated in the diff.\n\n--- .kogen/intents/fixture/acceptance.feature (added; mode 100644)\nFeature: Integration fixture\n",
		"\n--- app.txt\ncandidate\n\n--- features/steps/integration_steps.js (added; mode 100644)\n// steps\n",
	} {
		contains(t, "source", source, part)
	}

	res := e.result(id)
	eq(t, "passes", res["passes"], any(float64(1)))
	eq(t, "reviews", res["reviews"], any(float64(1)))
	review := e.jsonFile(e.runPath(id, "review-1.json"))
	eq(t, "model", review["model"], any(defaultRole().Model))
	eq(t, "verdict", review["verdict"], any("approve"))
	eq(t, "tree", review["tree"], any(e.gitOut("rev-parse", "HEAD^{tree}")))
	if attempts := review["attempts"].([]any); len(attempts) != 1 || attempts[0].(map[string]any)["verdict"] != "approve" {
		t.Fatalf("attempts %v", attempts)
	}
	usage := review["usage"].(map[string]any)
	eq(t, "review input tokens", usage["input"], any(float64(1)))
	events := eventsNamed(e.events(id), "review")
	if len(events) != 1 || events[0]["attempt"] != float64(1) || events[0]["verdict"] != "approve" {
		t.Fatalf("review events %v", events)
	}
}

func TestAReviewerRepairIsVerifiedAndCommittedWithoutReturningToTheBuilder(t *testing.T) {
	t.Parallel()
	// ExUnit: test/integration/build_boundaries_test.exs: REV-5 reviewer repairs are verified and committed without returning to the builder
	e := newEnv(t)
	f := e.prov
	f.then(landScript(f)...)
	f.then(f.calls(append(writeApp("reviewer repair\n"), "submit_review", map[string]any{"verdict": "approve", "findings": []any{}})...))
	a := e.reviewed()
	if a.exit != 0 {
		t.Fatalf("exit %d\n%s", a.exit, a.shown())
	}
	id := e.onlyRun()
	eq(t, "committed", e.gitOut("show", "HEAD:app.txt"), "reviewer repair")
	res := e.result(id)
	eq(t, "passes", res["passes"], any(float64(2)))
	eq(t, "reviews", res["reviews"], any(float64(1)))
	eq(t, "requests", f.count(), 2)
	review := e.jsonFile(e.runPath(id, "review-1.json"))
	eq(t, "approved tree", review["tree"], any(e.gitOut("rev-parse", "HEAD^{tree}")))
	passes := eventsNamed(e.events(id), "pass")
	if len(passes) != 2 || passes[1]["green"] != true {
		t.Fatalf("passes %v", passes)
	}
	// The reviewer's tool use is in the run log.
	calls := eventsNamed(e.events(id), "review_tool_call")
	if len(calls) != 1 || calls[0]["name"] != "write_file" {
		t.Fatalf("review tool calls %v", calls)
	}
}

func TestFinalVerificationFailuresReturnToTheSameReviewerContext(t *testing.T) {
	t.Parallel()
	// ExUnit: test/integration/build_boundaries_test.exs: REV-5 final verification failures return to the same reviewer context
	e := newEnv(t, func(c *project.Config) { c.Checks = []project.Check{{Name: "tidy", Run: "! grep -qx broken app.txt"}} })
	e.approve()
	f := e.prov
	f.then(landScript(f)...)
	approve := map[string]any{"verdict": "approve", "findings": []any{}}
	f.then(
		f.calls(append(writeApp("broken\n"), "submit_review", approve)...),
		f.calls(append(writeApp("reviewer repaired\n"), "submit_review", approve)...),
	)
	a := e.reviewed()
	if a.exit != 0 {
		t.Fatalf("exit %d\n%s", a.exit, a.shown())
	}
	id := e.onlyRun()
	eq(t, "committed", e.gitOut("show", "HEAD:app.txt"), "reviewer repaired")
	contains(t, "stdout", a.out.String(), "  repairs: 1 · ")
	res := e.result(id)
	eq(t, "passes", res["passes"], any(float64(3)))
	eq(t, "reviews", res["reviews"], any(float64(1)))
	reqs := f.reviewRequests()
	if len(reqs) != 2 {
		t.Fatalf("%d review requests", len(reqs))
	}
	first, second := requestInput(reqs[0]), requestInput(reqs[1])
	if !reflect.DeepEqual(second[:len(first)], first) {
		t.Fatal("the second request does not continue the first conversation")
	}
	text := requestText(reqs[1])
	contains(t, "second request", text, "Final verification of your repairs failed.")
	contains(t, "second request", text, "check tidy (! grep -qx broken app.txt): failed, exit status 1")
	contains(t, "second request", text, "use submit_review changes with a blocking finding at that protected path")
	contains(t, "second request", text, "then call submit_review again")
	contains(t, "second request", text, `"write_file"`)
	review := e.jsonFile(e.runPath(id, "review-1.json"))
	if attempts := review["attempts"].([]any); len(attempts) != 2 {
		t.Fatalf("attempts %v", attempts)
	}
	// The failed pass belongs to the reviewer: no builder round started.
	eq(t, "requests", f.count(), 3)
	eq(t, "rounds", len(eventsNamed(e.events(id), "pass")), 3)
}

func TestOneInvalidVerdictIsSentBackAndASecondEndsTheBuild(t *testing.T) {
	t.Parallel()
	// ExUnit: test/integration/release_behavior_test.exs: REV-4/REV-5 retries one invalid review verdict and lands after approval
	bad := finding("blocking", "An approve verdict cannot contain a blocking finding.")
	t.Run("retried once", func(t *testing.T) {
		t.Parallel()
		e := newEnv(t)
		f := e.prov
		f.then(landScript(f)...)
		f.then(submit(f, "approve", bad), submit(f, "approve"))
		a := e.reviewed()
		if a.exit != 0 {
			t.Fatalf("exit %d\n%s", a.exit, a.shown())
		}
		reqs := f.reviewRequests()
		eq(t, "review requests", len(reqs), 2)
		contains(t, "retry", requestText(reqs[1]), "invalid verdict:\\nan approve verdict cannot have blocking findings")
		id := e.onlyRun()
		review := e.jsonFile(e.runPath(id, "review-1.json"))
		eq(t, "attempts", len(review["attempts"].([]any)), 1)
	})
	t.Run("problems sent back", func(t *testing.T) {
		cases := map[string]struct {
			args any
			want string
		}{
			"unknown path": {map[string]any{"verdict": "changes", "findings": []any{map[string]any{"path": "nowhere.txt", "line": 3, "severity": "blocking", "message": "x"}}}, "nowhere.txt is not a file of the repository"},
			"no blocker":   {map[string]any{"verdict": "changes", "findings": []any{finding("note", "x")}}, "a changes verdict needs at least one blocking finding"},
			"bad finding":  {map[string]any{"verdict": "approve", "findings": []any{map[string]any{"path": "app.txt", "line": 1.5, "severity": "note", "message": "x"}}}, "each finding needs path (string), line (integer), severity (blocking or note) and message"},
			"no verdict":   {map[string]any{"verdict": "maybe", "findings": []any{}}, "submit_review needs verdict (approve or changes) and a findings list; verdict must be approve or changes but was a string with an unsupported value"},
			"no findings":  {map[string]any{"verdict": "approve"}, "submit_review needs verdict (approve or changes) and a findings list; findings must be a JSON array of objects but was missing"},
		}
		for i, row := range reviewShapeCases() {
			if row.accepted {
				continue
			}
			cases[fmt.Sprintf("matrix %d", i)] = struct {
				args any
				want string
			}{decodeReviewArgs(t, row.args), row.problem}
		}
		for name, tc := range cases {
			t.Run(name, func(t *testing.T) {
				t.Parallel()
				e := newEnv(t)
				f := e.prov
				f.then(landScript(f)...)
				f.then(f.calls("submit_review", tc.args), submit(f, "approve"))
				a := e.reviewed()
				eq(t, "exit", a.exit, 0)
				reqs := f.reviewRequests()
				eq(t, "review requests", len(reqs), 2)
				var outputs []string
				for _, raw := range requestInput(reqs[1]) {
					item, _ := raw.(map[string]any)
					if item["type"] == "function_call_output" {
						output, _ := item["output"].(string)
						outputs = append(outputs, output)
					}
				}
				eq(t, "submit_review tool output", outputs, []string{"invalid verdict:\n" + tc.want})
				if strings.Contains(strings.Join(outputs, ""), "PRIVATE_REVIEW_MARKER") {
					t.Fatal("private value disclosed")
				}
			})
		}
	})
	t.Run("a reply without a verdict is invalid, twice ends the Build", func(t *testing.T) {
		t.Parallel()
		e := newEnv(t)
		f := e.prov
		f.then(landScript(f)...)
		say := sse(map[string]any{"type": "message", "id": "msg-1", "role": "assistant", "content": []any{map[string]any{"type": "output_text", "text": "All good."}}})
		f.then(say, say)
		start := e.head()
		a := e.reviewed()
		eq(t, "exit", a.exit, 1)
		id := e.onlyRun()
		out := a.out.String()
		contains(t, "stdout", out, "failed fixture: review_invalid (Build "+id+")\ncandidate/review_invalid: the reviewer did not return a valid verdict; edits are left in place\n")
		contains(t, "stdout", out, "  still failing: review\n")
		eq(t, "head", e.head(), start)
		reqs := f.reviewRequests()
		eq(t, "review requests", len(reqs), 2)
		contains(t, "retry", requestText(reqs[1]), "Not a valid verdict: the review ended without calling submit_review. Call submit_review.")
		eq(t, "outcome", e.result(id)["outcome"], any("review_invalid"))
	})
}

func TestReviewerToolsAreProtectedLikeTheBuilders(t *testing.T) {
	t.Parallel()
	// ExUnit: test/integration/build_boundaries_test.exs: REV-6 reviewer shell edits cannot change the approved baseline
	e := newEnv(t)
	f := e.prov
	f.then(landScript(f)...)
	f.then(f.calls("shell", map[string]any{"command": "printf changed > .kogen/intents/fixture/acceptance.feature"},
		"submit_review", map[string]any{"verdict": "approve", "findings": []any{}}))
	start := e.head()
	a := e.reviewed()
	eq(t, "exit", a.exit, 1)
	contains(t, "stdout", a.shown(), "candidate/baseline_changed")
	eq(t, "head", e.head(), start)
	eq(t, "outcome", e.result(e.onlyRun())["outcome"], any("baseline_changed"))
	// write_file refuses a protected path.
	e2 := newEnv(t)
	f2 := e2.prov
	f2.then(landScript(f2)...)
	f2.then(f2.calls("write_file", map[string]any{"path": ".kogen/intents/fixture/acceptance.feature", "content": "x"}), submit(f2, "approve"))
	a2 := e2.reviewed()
	eq(t, "exit", a2.exit, 0)
	contains(t, "refusal", requestText(f2.reviewRequests()[1]), "refused")
	eq(t, "feature", e2.read(project.FeaturePath(testSlug)), testFeature)
}

func TestAnInterruptedReviewResumesInTheSameReviewerConversation(t *testing.T) {
	t.Parallel()
	// ExUnit: test/integration/build_boundaries_test.exs: resuming pending reviewer verification keeps repairs with the reviewer
	e := newEnv(t)
	f := e.prov
	f.then(landScript(f)...)
	opened := make(chan struct{})
	f.then(f.calls("read_file", map[string]any{"path": "app.txt"}), hang(opened))
	a, done := e.startReviewed()
	<-opened
	a.s.Interrupt("SIGINT")
	<-done
	eq(t, "exit", a.exit, 130)
	id := e.onlyRun()
	cont, session := sessionOfRun(t, e, id)
	eq(t, "stage", cont["stage"], any("review"))
	if session == nil || len(session["input"].([]any)) < 3 {
		t.Fatalf("session %v", session)
	}
	res := e.result(id)
	eq(t, "unknown requests", res["unknown_requests"], any(float64(1)))
	facts := e.jsonFile(filepath.Join(e.root, ".kogen/local/facts", id+".json"))
	eq(t, "resume status", facts["resume_status"], any("potentially_available"))
	eq(t, "requests so far", len(f.reviewRequests()), 2)

	f.replace(submit(f, "approve"))
	r := e.resumeReviewed(id)
	if r.exit != 0 {
		t.Fatalf("exit %d\n%s", r.exit, r.shown())
	}
	contains(t, "stdout", r.out.String(), "landed fixture ")
	reqs := f.reviewRequests()
	eq(t, "review requests", len(reqs), 3)
	if !reflect.DeepEqual(requestInput(reqs[1]), requestInput(reqs[2])) {
		t.Fatalf("the resumed request is not the interrupted one:\n%s\n%s", requestText(reqs[1]), requestText(reqs[2]))
	}
	if len(requestInput(reqs[2])) < 3 {
		t.Fatal("the read was not part of the conversation")
	}
	ids := e.runIDs()
	eq(t, "runs", len(ids), 2)
	child := ids[0]
	if child == id {
		child = ids[1]
	}
	cr := e.result(child)
	eq(t, "reviews", cr["reviews"], any(float64(1)))
	eq(t, "resumed_from", cr["resumed_from"], any(id))
	review := e.jsonFile(e.runPath(child, "review-1.json"))
	eq(t, "verdict", review["verdict"], any("approve"))
	// Builder requests: one. The reviewer's usage is cumulative.
	eq(t, "total requests", f.count(), 4)
	eq(t, "review input tokens", review["usage"].(map[string]any)["input"], any(float64(2)))
}

func TestAnInterruptedTargetedRepairReportsPendingReviewAndChangedVerification(t *testing.T) {
	t.Parallel()
	// ExUnit: test/integration/build_boundaries_test.exs: REV-5 interrupted targeted repair reports pending review and changed verification
	aux := t.TempDir()
	mutated := filepath.Join(aux, "check-mutated")
	e := newEnv(t, func(c *project.Config) {
		c.Checks = []project.Check{{Name: "mutate", Run: "if grep -qx 'reviewer repair' app.txt && ! test -f '" + mutated + "'; then printf 'check mutation\\n' > app.txt; touch '" + mutated + "'; fi"}}
	})
	e.approve()
	f := e.prov
	f.then(landScript(f)...)
	waiting := filepath.Join(aux, "reviewer-waiting")
	f.then(
		f.calls(append(writeApp("reviewer repair\n"), "submit_review", map[string]any{"verdict": "approve", "findings": []any{}})...),
		f.calls("shell", map[string]any{"command": "touch '" + waiting + "'; sleep 600"}),
	)
	a, done := e.startReviewed()
	for i := 0; i < 600; i++ {
		if _, err := os.Stat(waiting); err == nil {
			break
		}
		sleepBriefly()
	}
	a.s.Interrupt("SIGINT")
	<-done
	eq(t, "exit", a.exit, 130)
	id := e.onlyRun()
	res := e.result(id)
	eq(t, "outcome", res["outcome"], any("interrupted"))
	still := []string{}
	for _, s := range res["still_failing"].([]any) {
		still = append(still, s.(string))
	}
	slices.Sort(still)
	if !slices.Equal(still, []string{"review", "verification"}) {
		t.Fatalf("still failing %v", still)
	}
	eq(t, "app.txt", e.read("app.txt"), "reviewer repair\n")
	review := e.jsonFile(e.runPath(id, "review-1.json"))
	if attempts := review["attempts"].([]any); len(attempts) != 1 || attempts[0].(map[string]any)["verdict"] != "approve" {
		t.Fatalf("attempts %v", attempts)
	}
	contains(t, "second request", requestText(f.reviewRequests()[0]), "# Check results")
	// The shell call is an uncertain tool boundary: it cannot be resumed.
	r := e.resumeReviewed(id)
	eq(t, "resume exit", r.exit, 1)
	contains(t, "resume", r.shown(), "candidate/resume_refused: Build "+id+": uncertain tool boundary")
}

func TestABlockedReviewStopsAndAnExplicitResumeReopensItUnderTheSameReviewer(t *testing.T) {
	t.Parallel()
	// ExUnit: test/integration/build_boundaries_test.exs: REV-5 unresolved substantive findings stop rather than start another builder round
	// ExUnit: .kogen/intents/reopen-blocked-review: explicit resume replaces terminal changes replay with fresh verification and same-reviewer explicit clearance
	e := newEnv(t)
	f := e.prov
	f.then(landScript(f)...)
	blocker := finding("blocking", "Original unresolved requirement")
	f.then(submit(f, "changes", blocker))
	start := e.head()
	a := e.reviewed()
	eq(t, "exit", a.exit, 1)
	id := e.onlyRun()
	out := a.out.String()
	contains(t, "stdout", out, "failed fixture: review_blocked (Build "+id+")\ncandidate/review_blocked: the reviewer could not resolve a substantive blocker within the approved Intent; edits are left in place\n  review: app.txt:1: Original unresolved requirement\n")
	contains(t, "stdout", out, "  still failing: review\n")
	eq(t, "head", e.head(), start)
	if _, err := os.Stat(project.ApprovalPath(e.root, testSlug)); err != nil {
		t.Fatalf("the approval was removed: %v", err)
	}
	res := e.result(id)
	eq(t, "outcome", res["outcome"], any("review_blocked"))
	eq(t, "reviews", res["reviews"], any(float64(1)))
	cont, _ := sessionOfRun(t, e, id)
	eq(t, "stage", cont["stage"], any("review_verify"))
	original, err := os.ReadFile(e.runPath(id, "checkpoint.json"))
	if err != nil {
		t.Fatal(err)
	}
	index := e.state()["index"]

	// Resume 1: fresh verification, the reviewer keeps the blocker: stops again.
	f.then(submit(f, "changes", blocker))
	r1 := e.resumeReviewed(id)
	eq(t, "exit", r1.exit, 1)
	contains(t, "stdout", r1.out.String(), "candidate/review_blocked: ")
	contains(t, "stdout", r1.out.String(), "  review: app.txt:1: Original unresolved requirement\n")
	eq(t, "head", e.head(), start)
	eq(t, "index", e.state()["index"], index)
	now, _ := os.ReadFile(e.runPath(id, "checkpoint.json"))
	if string(now) != string(original) {
		t.Fatal("the blocked run's checkpoint changed")
	}
	child := e.otherRun(id)
	cr := e.result(child)
	eq(t, "passes", cr["passes"], any(float64(2)))
	eq(t, "reviews", cr["reviews"], any(float64(1)))
	eq(t, "resumed_from", cr["resumed_from"], any(id))
	eq(t, "root_build", cr["root_build"], any(id))
	reqs := f.reviewRequests()
	eq(t, "review requests", len(reqs), 2)
	first, second := requestInput(reqs[0]), requestInput(reqs[1])
	if !reflect.DeepEqual(second[:len(first)], first) {
		t.Fatal("the reopened review is not the same conversation")
	}
	feedback := second[len(second)-1].(map[string]any)["content"].(string)
	for _, part := range []string{
		"The caller explicitly resumed this blocked Build. Continue as the same independent\nreviewer for targeted clearance or scoped repair, not a new whole-change critique.\n",
		"The original blocking finding remains unresolved until your new explicit decision:\n[{",
		"Original unresolved requirement",
		"Earlier green evidence and approval do not clear this blocker. Fresh verification:\nacceptance: passed (2 scenarios)\nmodel: not applicable\n",
		"edits still require ordinary external exact verification before commit.\n",
	} {
		contains(t, "feedback", feedback, part)
	}
	cont2, session2 := sessionOfRun(t, e, child)
	eq(t, "stage", cont2["stage"], any("review_verify"))
	if v := session2["verdict"].(map[string]any); v["verdict"] != "changes" {
		t.Fatalf("verdict %v", v)
	}

	// Resume 2: the reviewer clears the blocker; the unchanged green tree commits.
	f.then(submit(f, "approve"))
	r2 := e.resumeReviewed(child)
	if r2.exit != 0 {
		t.Fatalf("exit %d\n%s", r2.exit, r2.shown())
	}
	contains(t, "stdout", r2.out.String(), "landed fixture ")
	eq(t, "commits", e.gitOut("rev-list", "--count", start+"..HEAD"), "1")
	last := e.otherRun(id, child)
	lr := e.result(last)
	eq(t, "passes", lr["passes"], any(float64(3)))
	eq(t, "reviews", lr["reviews"], any(float64(1)))
	eq(t, "root_build", lr["root_build"], any(id))
	review := e.jsonFile(e.runPath(last, "review-1.json"))
	attempts := review["attempts"].([]any)
	if len(attempts) != 3 || attempts[0].(map[string]any)["verdict"] != "changes" || attempts[1].(map[string]any)["verdict"] != "changes" || attempts[2].(map[string]any)["verdict"] != "approve" {
		t.Fatalf("attempts %v", attempts)
	}
	eq(t, "builder requests", f.count()-len(f.reviewRequests()), 1)
	if _, err := os.Stat(project.ApprovalPath(e.root, testSlug)); !os.IsNotExist(err) {
		t.Fatal("the approval stayed after the commit")
	}
}

func (e *env) otherRun(except ...string) string {
	e.t.Helper()
	for _, id := range e.runIDs() {
		if !slices.Contains(except, id) {
			return id
		}
	}
	e.t.Fatal("no other run")
	return ""
}

func TestAReopenedReviewSeesFreshRedResultsAndStaleApprovalCannotClearIt(t *testing.T) {
	t.Parallel()
	// ExUnit: .kogen/intents/reopen-blocked-review: complete fresh verification is required and stale green/approval cannot override unresolved, fresh-red or setup-failed blockers
	flag := filepath.Join(t.TempDir(), "gate-red")
	e := newEnv(t, func(c *project.Config) {
		c.Checks = []project.Check{{Name: "gate", Run: "test ! -f '" + flag + "'"}}
	})
	e.approve()
	f := e.prov
	f.then(landScript(f)...)
	f.then(submit(f, "changes", finding("blocking", "Original unresolved requirement")))
	start := e.head()
	a := e.reviewed()
	eq(t, "exit", a.exit, 1)
	id := e.onlyRun()
	writeFile(t, flag, "red", 0o644)
	f.then(submit(f, "changes", finding("blocking", "Still unresolved")))
	r := e.resumeReviewed(id)
	eq(t, "exit", r.exit, 1)
	out := r.out.String()
	contains(t, "stdout", out, "  review: app.txt:1: Still unresolved\n")
	contains(t, "stdout", out, "  still failing: gate, review\n")
	eq(t, "head", e.head(), start)
	child := e.otherRun(id)
	reqs := f.reviewRequests()
	feedback := requestInput(reqs[1])
	text := feedback[len(feedback)-1].(map[string]any)["content"].(string)
	contains(t, "feedback", text, "Verification pass 2 is not green.")
	contains(t, "feedback", text, "check gate (test ! -f '"+flag+"'): failed, exit status 1")
	lacks(t, "feedback", text, "acceptance: passed")
	res := e.result(child)
	eq(t, "passes", res["passes"], any(float64(2)))

	// With the failure gone, an approval after fresh green verification lands.
	os.Remove(flag)
	f.then(submit(f, "approve"))
	r2 := e.resumeReviewed(child)
	if r2.exit != 0 {
		t.Fatalf("exit %d\n%s", r2.exit, r2.shown())
	}
	eq(t, "commits", e.gitOut("rev-list", "--count", start+"..HEAD"), "1")
	eq(t, "passes", e.result(e.otherRun(id, child))["passes"], any(float64(3)))
}

func TestABlockedRetryThatFailsAtTheContinuedRequestKeepsFreshEvidenceAndTheSavedReviewer(t *testing.T) {
	t.Parallel()
	// ExUnit: test/integration/build_boundaries_test.exs: blocked #{retry_outcome} retry provider failure retains fresh evidence and the saved reviewer
	for _, setupRed := range []bool{false, true} {
		name := "green"
		if setupRed {
			name = "setup red"
		}
		t.Run(name, func(t *testing.T) {
			aux := t.TempDir()
			trace, red := filepath.Join(aux, "setup-trace"), filepath.Join(aux, "setup-red")
			e := newEnv(t, func(c *project.Config) {
				c.Setup = []string{"echo setup >> '" + trace + "'; if test -f '" + red + "'; then echo retry-setup-failure; exit 23; fi"}
			})
			e.approve()
			f := e.prov
			f.then(landScript(f)...)
			blocker := finding("blocking", "Original unresolved requirement")
			f.then(submit(f, "changes", blocker), failure(400, "invalid_request_error", "continued request failed"), submit(f, "approve"))
			a := e.reviewed()
			eq(t, "exit", a.exit, 1)
			contains(t, "stdout", a.shown(), "review_blocked")
			original := e.onlyRun()
			originalCheckpoint, _ := os.ReadFile(e.runPath(original, "checkpoint.json"))
			writeFile(t, trace, "", 0o644)
			if setupRed {
				writeFile(t, red, "red", 0o644)
			}
			r := e.resumeReviewed(original)
			if r.exit == 0 {
				t.Fatalf("a failed continued request exits 0\n%s", r.shown())
			}
			child := e.otherRun(original)
			cr := e.result(child)
			eq(t, "passes", cr["passes"], any(float64(2)))
			eq(t, "unknown requests", cr["unknown_requests"], any(float64(1)))
			if !slices.Contains(toStrings(cr["still_failing"]), "review") {
				t.Fatalf("still failing %v", cr["still_failing"])
			}
			b, _ := os.ReadFile(e.runPath(child, "checkpoint.json"))
			childCheckpoint := string(b)
			eq(t, "setup runs", readString(t, trace), "setup\n")
			cont, _ := sessionOfRun(t, e, child)
			eq(t, "stage", cont["stage"], any("review"))
			pass := cont["pass"].(map[string]any)
			if setupRed {
				eq(t, "pass green", pass["green"], any(false))
				if !reflect.DeepEqual(pass["not_run"], []any{"acceptance"}) {
					t.Fatalf("not_run %v", pass["not_run"])
				}
				if setup := pass["setup"].([]any); len(setup) != 1 || setup[0].(map[string]any)["status"] != float64(23) {
					t.Fatalf("setup %v", setup)
				}
				os.Remove(red)
			} else {
				eq(t, "pass green", pass["green"], any(true))
			}

			r2 := e.resumeReviewed(child)
			if r2.exit != 0 {
				t.Fatalf("exit %d\n%s", r2.exit, r2.shown())
			}
			final := e.otherRun(original, child)
			fr := e.result(final)
			want := 2.0
			wantTrace := "setup\n"
			if setupRed {
				want, wantTrace = 3, "setup\nsetup\n"
			}
			eq(t, "passes", fr["passes"], any(want))
			eq(t, "setup runs", readString(t, trace), wantTrace)
			eq(t, "unknown requests", fr["unknown_requests"], any(float64(1)))
			eq(t, "usage input", fr["usage"].(map[string]any)["input"], any(cr["usage"].(map[string]any)["input"].(float64)+1))
			if now, _ := os.ReadFile(e.runPath(child, "checkpoint.json")); string(now) != childCheckpoint {
				t.Fatal("the failed run's checkpoint changed")
			}
			eq(t, "reviews", fr["reviews"], any(float64(1)))
			if now, _ := os.ReadFile(e.runPath(original, "checkpoint.json")); string(now) != string(originalCheckpoint) {
				t.Fatal("the original checkpoint changed")
			}
			reqs := f.reviewRequests()
			eq(t, "review requests", len(reqs), 3)
			initial, failed, continued := requestInput(reqs[0]), requestInput(reqs[1]), requestInput(reqs[2])
			if !reflect.DeepEqual(failed, continued) {
				t.Fatal("the resent request differs from the failed one")
			}
			if !reflect.DeepEqual(continued[:len(initial)], initial) {
				t.Fatal("the continued request does not extend the initial conversation")
			}
			contains(t, "continued", requestText(reqs[2]), blocker["message"].(string))
			if setupRed {
				feedback := continued[len(continued)-1].(map[string]any)["content"].(string)
				contains(t, "feedback", feedback, "retry-setup-failure")
				contains(t, "feedback", feedback, "exit status 23")
				contains(t, "feedback", feedback, "not run because an earlier item failed: acceptance")
			}
		})
	}
}

func toStrings(v any) []string {
	var out []string
	for _, x := range v.([]any) {
		out = append(out, x.(string))
	}
	return out
}

func readString(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestTheReviewerReadsTheFullSourceAndNewFilesAppearOnce(t *testing.T) {
	t.Parallel()
	// ExUnit: test/integration/build_boundaries_test.exs: REV-2 review retains full source without replaying new files twice
	e := newEnv(t)
	before := "outside-diff-sentinel\n" + strings.Repeat("context\n", 20) + "old marker\n"
	after := strings.ReplaceAll(before, "old marker", "new marker")
	e.write("existing-context.txt", before)
	e.write("rename-from.txt", "renamed-source-sentinel\n")
	e.run("git", "add", "existing-context.txt", "rename-from.txt")
	e.run("git", "commit", "--only", "-qm", "Add review context fixture", "--", "existing-context.txt", "rename-from.txt")
	f := e.prov
	f.then(f.calls(
		"write_file", map[string]any{"path": "new-source.txt", "content": "new-source-sentinel\n"},
		"write_file", map[string]any{"path": "existing-context.txt", "content": after},
		"shell", map[string]any{"command": "chmod 755 new-source.txt && printf '\\000\\001\\002' > new-data.bin && mv rename-from.txt rename-to.txt"},
		"shell", map[string]any{"command": "git init -q new-submodule && git -C new-submodule -c user.name=Fixture -c user.email=fixture@example.test -c commit.gpgsign=false commit --allow-empty -qm 'Nested fixture'"},
		"write_file", map[string]any{"path": "app.txt", "content": "candidate\n"},
		"finish", map[string]any{"summary": "done"},
	))
	f.then(submit(f, "approve"))
	a := e.reviewed()
	if a.exit != 0 {
		t.Fatalf("exit %d\n%s", a.exit, a.shown())
	}
	reqs := f.reviewRequests()
	eq(t, "review requests", len(reqs), 1)
	material := requestText(reqs[0])
	// The text is JSON-escaped in requestText: decode the blocks instead.
	blocks := requestInput(reqs[0])[0].(map[string]any)["content"].([]any)
	material = blocks[0].(map[string]any)["text"].(string) + blocks[1].(map[string]any)["text"].(string)
	count := func(s string) int { return strings.Count(material, s) }
	eq(t, "new-source-sentinel", count("new-source-sentinel"), 1)
	contains(t, "material", material, "100755")
	contains(t, "material", material, "--- new-data.bin (added; mode 100644) (binary)")
	contains(t, "material", material, "deleted file mode 100644")
	contains(t, "material", material, "--- rename-from.txt (deleted)")
	contains(t, "material", material, "--- rename-to.txt (added; mode 100644)\nrenamed-source-sentinel")
	submodule := strings.TrimSpace(e.run("git", "-C", "new-submodule", "rev-parse", "HEAD"))
	contains(t, "material", material, "--- new-submodule (added; mode 160000)\nSubproject commit "+submodule)
	lacks(t, "material", material, "--- new-submodule (deleted)")
	contains(t, "material", material, "-old marker")
	contains(t, "material", material, "+new marker")
	contains(t, "material", material, after)
	eq(t, "outside-diff-sentinel", count("outside-diff-sentinel"), 1)
}

// readPinned reads, one per response, the source parts pinned in the run folders, then approves.
// One handler keeps its place for every request it answers.
func readPinned(e *env, f *fakeProvider) handler {
	next := 0
	return func(w http.ResponseWriter, r *http.Request) {
		parts, _ := filepath.Glob(filepath.Join(e.root, ".kogen/local/runs/*/review-source/*/*.json"))
		slices.Sort(parts)
		if next >= len(parts) {
			submit(f, "approve")(w, r)
			return
		}
		path := parts[next]
		next++
		f.calls("read_file", map[string]any{"path": path})(w, r)
	}
}

func TestTheReviewAndItsResetsCarryOnlyTheFrozenCallerDiagnostic(t *testing.T) {
	t.Parallel()
	// ExUnit: test/integration/build_context_files_test.exs: fresh independent review and its resets retain only frozen caller diagnostics, not builder reasoning
	e := newEnv(t)
	f := e.prov
	f.then(f.calls("finish", map[string]any{"summary": "builder-only-reasoning-sentinel"}))
	// The builder finished with the unchanged file: the baseline is green; the reviewer grows its
	// conversation past the working window three times; its candidate source, still inline in
	// its opening message, is then pinned to private parts it must read before approving.
	for i := 0; i < 3; i++ {
		f.then(f.calls("write_file", map[string]any{"path": ".kogen/local/padding", "content": strings.Repeat("x", 190_000)}))
	}
	f.then(f.calls("read_file", map[string]any{"path": "app.txt"}))
	shared := readPinned(e, f)
	for i := 0; i < 40; i++ {
		f.then(shared)
	}
	text := "  frozen selective reuse Δ🙂\r\nnot approval or old green proof\n"
	d := &Diagnostic{Text: text, SourcePath: "/diagnostic/label.txt", SHA256: digestOf(text)}
	a := e.reviewed(func(in *Input) { in.Context = d })
	if a.exit != 0 {
		t.Fatalf("exit %d\n%s", a.exit, a.shown())
	}
	contains(t, "progress", a.errs.String(), "review local reset")
	parts, _ := filepath.Glob(filepath.Join(e.root, ".kogen/local/runs/*/review-source/*/*.json"))
	if len(parts) == 0 {
		t.Fatal("the inline source was never pinned")
	}
	reqs := f.reviewRequests()
	eq(t, "review requests", len(reqs), 5+len(parts))
	for i, req := range reqs {
		var all strings.Builder
		for _, it := range requestInput(req) {
			m := it.(map[string]any)
			switch c := m["content"].(type) {
			case string:
				all.WriteString(c)
			case []any:
				for _, b := range c {
					all.WriteString(b.(map[string]any)["text"].(string))
				}
			}
		}
		material := all.String()
		if !strings.Contains(material, text) || !strings.Contains(material, "lower-authority data") {
			t.Fatalf("request %d lacks the frozen diagnostic", i+1)
		}
		lacks(t, "request", requestText(req), "builder-only-reasoning-sentinel")
	}
}

// ---- large source: pinned parts ----

// reviewCatalog is the pinned source catalog of a review request.
func reviewCatalog(t *testing.T, req map[string]any) map[string]any {
	t.Helper()
	blocks := requestInput(req)[0].(map[string]any)["content"].([]any)
	text := blocks[1].(map[string]any)["text"].(string)
	_, rest, ok := strings.Cut(text, "# Pinned complete candidate source evidence\n")
	if !ok {
		t.Fatalf("no catalog in %.200s", text)
	}
	line, _, _ := strings.Cut(rest, "\n")
	var catalog map[string]any
	if err := json.Unmarshal([]byte(line), &catalog); err != nil {
		t.Fatal(err)
	}
	return catalog
}

func catalogParts(catalog map[string]any) []string {
	var out []string
	for _, p := range catalog["parts"].([]any) {
		out = append(out, p.(map[string]any)["path"].(string))
	}
	return out
}

// readParts reads the pinned parts of the first review request in batches of n and then
// approves.
func readParts(f *fakeProvider, n int) handler {
	var parts []string
	next := 0
	return func(w http.ResponseWriter, r *http.Request) {
		if parts == nil {
			reqs := f.reviewRequests()
			parts = catalogParts(reviewCatalog(f.t, reqs[0]))
		}
		if next >= len(parts) {
			submit(f, "approve")(w, r)
			return
		}
		var pairs []any
		for _, p := range parts[next:min(next+n, len(parts))] {
			pairs = append(pairs, "read_file", map[string]any{"path": p})
		}
		next += n
		f.calls(pairs...)(w, r)
	}
}

func bigFile() string { return strings.Repeat("0123456789abcdef-line\n", 14_000) }

func TestLargeSourceIsDeliveredAsPinnedPartsAndMustBeReadBeforeApproval(t *testing.T) {
	t.Parallel()
	// ExUnit: test/integration/review_material_test.exs: exact UTF8 source delivery survives reset and damaged custody refuses
	e := newEnv(t)
	f := e.prov
	content := bigFile()
	f.then(f.calls("write_file", map[string]any{"path": "app.txt", "content": content}, "finish", map[string]any{"summary": "done"}))
	// One handler keeps the reading's progress for every request.
	shared := readParts(f, 15)
	for i := 0; i < 30; i++ {
		f.then(shared)
	}
	a := e.reviewed()
	if a.exit != 0 {
		t.Fatalf("exit %d\n%s\n%s", a.exit, a.shown(), a.errs)
	}
	id := e.onlyRun()
	reqs := f.reviewRequests()
	catalog := reviewCatalog(t, reqs[0])
	parts := catalogParts(catalog)
	if len(parts) < 20 || len(reqs) < 4 {
		t.Fatalf("%d parts, %d review requests", len(parts), len(reqs))
	}
	eq(t, "catalog version", catalog["version"], any(float64(1)))
	eq(t, "start head", catalog["start_head"], any(e.gitOut("rev-parse", "HEAD^")))
	eq(t, "candidate tree", catalog["candidate_tree"], any(e.gitOut("rev-parse", "HEAD^{tree}")))
	files := catalog["files"].([]any)
	var file map[string]any
	var paths []string
	for _, x := range files {
		m := x.(map[string]any)
		paths = append(paths, m["path"].(string))
		if m["path"] == "app.txt" {
			file = m
		}
	}
	if file == nil || !slices.Equal(paths, []string{".kogen/intents/fixture/acceptance.feature", ".kogen/intents/fixture/intent.md", "app.txt", "features/steps/integration_steps.js"}) {
		t.Fatalf("files %v", paths)
	}
	eq(t, "path", file["path"], any("app.txt"))
	eq(t, "status", file["status"], any("changed"))
	eq(t, "mode", file["mode"], any("100644"))
	eq(t, "bytes", file["bytes"], any(float64(len(content))))
	eq(t, "sha256", file["sha256"], any(hashHex([]byte(content))))
	eq(t, "git object", file["git_object"], any(e.gitOut("rev-parse", "HEAD:app.txt")))

	var source strings.Builder
	for n, p := range parts {
		eq(t, "part path", p, filepath.Join(e.root, ".kogen/local/runs", id, "review-source", "1-"+catalog["candidate_tree"].(string), itoa(n+1)+".json"))
		data, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		if st, _ := os.Stat(p); st.Mode().Perm() != 0o600 {
			t.Fatalf("mode %v", st.Mode().Perm())
		}
		if st, _ := os.Stat(filepath.Dir(p)); st.Mode().Perm() != 0o700 {
			t.Fatalf("folder mode %v", st.Mode().Perm())
		}
		var doc struct {
			Input        []any
			ReviewSource struct {
				Review, Part, Parts int
				Text                string
			} `json:"review_source"`
		}
		if err := json.Unmarshal(data, &doc); err != nil || len(doc.Input) != 0 {
			t.Fatalf("part %d: %v", n+1, err)
		}
		eq(t, "part number", doc.ReviewSource.Part, n+1)
		eq(t, "parts", doc.ReviewSource.Parts, len(parts))
		source.WriteString(doc.ReviewSource.Text)
	}
	eq(t, "source sha256", hashHex([]byte(source.String())), catalog["source_sha256"].(string))
	eq(t, "source bytes", float64(source.Len()), catalog["source_bytes"].(float64))
	contains(t, "source", source.String(), "# Diff of existing/deleted paths against start HEAD "+short(e.gitOut("rev-parse", "HEAD^")))
	contains(t, "source", source.String(), "--- app.txt\n"+content)

	// The opening message carries the catalog, never the source; every request fits.
	blocks := requestInput(reqs[0])[0].(map[string]any)["content"].([]any)
	lacks(t, "opening source block", blocks[1].(map[string]any)["text"].(string), "0123456789abcdef-line")
	reset := false
	for _, req := range f.requests() {
		raw, _ := json.Marshal(req)
		if len(raw) > 524_288+4096 {
			t.Fatalf("a request of %d bytes", len(raw))
		}
		reset = reset || strings.Contains(requestText(req), "Local working-window reset")
	}
	if !reset {
		t.Fatal("the reading did not outgrow the window: no reset")
	}
	evidence := eventsNamed(e.events(id), "review_source_evidence")
	if len(evidence) != 1 || evidence[0]["parts"] != float64(len(parts)) {
		t.Fatalf("evidence %v", evidence)
	}
	review := e.jsonFile(e.runPath(id, "review-1.json"))
	eq(t, "verdict", review["verdict"], any("approve"))
	eq(t, "committed", e.gitOut("show", "HEAD:app.txt")+"\n", content)
}

func TestApprovalNeedsEveryPinnedPartDeliveredInACompletedContinuation(t *testing.T) {
	t.Parallel()
	// ExUnit: test/integration/review_material_test.exs: exact UTF8 source delivery survives reset and damaged custody refuses (delivery before approval)
	e := newEnv(t)
	f := e.prov
	f.then(f.calls("write_file", map[string]any{"path": "app.txt", "content": bigFile()}, "finish", map[string]any{"summary": "done"}))
	var manual string
	f.then(func(w http.ResponseWriter, r *http.Request) {
		parts := catalogParts(reviewCatalog(f.t, f.reviewRequests()[0]))
		// Native prefill carries the unread parts from the front of the catalog, so the last
		// part is the one the first request cannot have carried (asserted below).
		manual = parts[len(parts)-1]
		// A read and an approval in one response deliver nothing.
		f.calls("read_file", map[string]any{"path": manual}, "submit_review", map[string]any{"verdict": "approve", "findings": []any{}})(w, r)
	}, submit(f, "approve"))
	start := e.head()
	a := e.reviewed()
	eq(t, "exit", a.exit, 1)
	id := e.onlyRun()
	contains(t, "stdout", a.out.String(), "failed fixture: review_invalid (Build "+id+")\ncandidate/review_invalid: the reviewer did not return a valid verdict; edits are left in place\n")
	eq(t, "head", e.head(), start)
	reqs := f.reviewRequests()
	eq(t, "review requests", len(reqs), 2)
	parts := catalogParts(reviewCatalog(t, reqs[0]))
	pinned := map[string]bool{}
	for _, p := range parts {
		pinned[p] = true
	}
	// What each answered request carried natively, each part verified byte for byte.
	prefilled1 := prefilledParts(t, reqs[0])
	prefilled2 := prefilledParts(t, reqs[1])
	for _, prefill := range []map[string]string{prefilled1, prefilled2} {
		for path := range prefill {
			if !pinned[path] {
				t.Fatalf("prefilled %s is not a pinned part", path)
			}
		}
	}
	if _, ok := prefilled1[manual]; ok {
		t.Fatalf("the part the response reads (%s) was already prefilled in its own request", manual)
	}
	if _, ok := prefilled2[manual]; ok {
		t.Fatalf("the part read in the first response (%s) was prefilled again after its read completed", manual)
	}
	// Unread parts, sorted as the approval check lists them, given the parts delivered so far.
	unreadAfter := func(delivered map[string]bool) []string {
		var left []string
		for _, p := range parts {
			if !delivered[p] {
				left = append(left, p)
			}
		}
		slices.Sort(left)
		return left
	}
	problemFor := func(left []string) string {
		return "Read all pinned source evidence before approving: " + itoa(len(left)) + " unread part(s); use read_file on " +
			strings.Join(left[:min(8, len(left))], ", ")
	}
	// First response: only its request's prefill was delivered; its own read is not yet.
	delivered := map[string]bool{}
	for path := range prefilled1 {
		delivered[path] = true
	}
	unread1 := unreadAfter(delivered)
	eq(t, "first unread", len(unread1), len(parts)-len(prefilled1))
	// Second response: the first prefill, the second request's prefill and the completed read.
	for path := range prefilled2 {
		delivered[path] = true
	}
	delivered[manual] = true
	unread2 := unreadAfter(delivered)
	if len(unread2) == 0 {
		t.Fatalf("the fixture delivered all %d parts", len(parts))
	}
	second := requestText(reqs[1])
	escaped, err := json.Marshal(problemFor(unread1))
	if err != nil {
		t.Fatal(err)
	}
	contains(t, "second", second, string(escaped[1:len(escaped)-1]))
	contains(t, "second", second, "invalid verdict:")
	// The second approval, after one completed read, still names the remaining parts.
	events := eventsNamed(e.events(id), "review")
	last := events[len(events)-1]
	eq(t, "verdict", last["verdict"], any("invalid"))
	problems := last["problems"].([]any)
	eq(t, "problem", problems[0].(string), problemFor(unread2))
	review := e.runPath(id, "review-1.json")
	if _, err := os.Stat(review); !os.IsNotExist(err) {
		t.Fatal("an invalid review has a review record")
	}
}

func TestSmallSourceIsDeliveredInline(t *testing.T) {
	t.Parallel()
	// ExUnit: test/integration/review_material_test.exs: small source remains inline without new custody
	e := newEnv(t)
	f := e.prov
	f.then(landScript(f)...)
	f.then(submit(f, "approve"))
	a := e.reviewed()
	eq(t, "exit", a.exit, 0)
	id := e.onlyRun()
	if _, err := os.Stat(filepath.Join(e.root, ".kogen/local/runs", id, "review-source")); !os.IsNotExist(err) {
		t.Fatal("source custody was created")
	}
	if n := len(eventsNamed(e.events(id), "review_source_evidence")); n != 0 {
		t.Fatalf("%d evidence events", n)
	}
}

func TestTheReviewerHasItsOwnImageAccess(t *testing.T) {
	t.Parallel()
	// ExUnit: .kogen/intents/native-image-evidence: resume frozen Build pixels and use fresh reviewer access (the reviewer's own view_image read and delivery)
	e := newEnv(t)
	img := image.NewRGBA(image.Rect(0, 0, 2, 2))
	for i := 0; i < 4; i++ {
		img.Set(i%2, i/2, color.RGBA{R: uint8(60 * i), G: 120, B: 200, A: 255})
	}
	var pixels bytes.Buffer
	if err := png.Encode(&pixels, img); err != nil {
		t.Fatal(err)
	}
	shot := ".kogen/local/shot.png"
	writeFile(t, filepath.Join(e.root, shot), pixels.String(), 0o644)
	f := e.prov
	f.then(landScript(f)...)
	f.then(f.calls("view_image", map[string]any{"path": shot}), submit(f, "approve"))
	a := e.reviewed()
	if a.exit != 0 {
		t.Fatalf("exit %d\n%s", a.exit, a.shown())
	}
	id := e.onlyRun()
	events := e.events(id)
	reads := eventsNamed(events, "image_read")
	if len(reads) != 1 || reads[0]["owner"] != "review" || reads[0]["status"] != "read" {
		t.Fatalf("image_read %v", reads)
	}
	deliveries := eventsNamed(events, "image_delivery")
	if len(deliveries) != 1 || deliveries[0]["owner"] != "review" || deliveries[0]["status"] != "completed" {
		t.Fatalf("image_delivery %v", deliveries)
	}
	eq(t, "sha256", deliveries[0]["sha256"], reads[0]["sha256"])
	// The pixels reach the reviewer's own continuation, never the builder's conversation.
	reqs := f.reviewRequests()
	eq(t, "review requests", len(reqs), 2)
	contains(t, "second request", requestText(reqs[1]), "input_image")
	lacks(t, "first request", requestText(reqs[0]), "input_image")
}

func TestAnInterruptedVerificationOfAReviewerRepairResumesWithoutANewRequest(t *testing.T) {
	t.Parallel()
	// ExUnit: test/integration/build_boundaries_test.exs: resuming pending reviewer verification keeps repairs with the reviewer
	paused := filepath.Join(t.TempDir(), "paused")
	e := newEnv(t, func(c *project.Config) {
		c.Checks = []project.Check{{Name: "pause", Run: "if grep -qx 'reviewer repair' app.txt && ! test -f '" + paused + "'; then touch '" + paused + "'; sleep 600; fi"}}
	})
	f := e.prov
	f.then(landScript(f)...)
	f.then(f.calls(append(writeApp("reviewer repair\n"), "submit_review", map[string]any{"verdict": "approve", "findings": []any{}})...))
	a, done := e.startReviewed()
	for i := 0; i < 600; i++ {
		if _, err := os.Stat(paused); err == nil {
			break
		}
		sleepBriefly()
	}
	a.s.Interrupt("SIGINT")
	<-done
	eq(t, "exit", a.exit, 130)
	id := e.onlyRun()
	contains(t, "stdout", a.out.String(), "  still failing: review\n")
	cont, session := sessionOfRun(t, e, id)
	eq(t, "stage", cont["stage"], any("review_verify"))
	if v := session["verdict"].(map[string]any); v["verdict"] != "approve" {
		t.Fatalf("verdict %v", v)
	}
	original := e.result(id)
	requests := f.count()
	r := e.resumeReviewed(id)
	if r.exit != 0 {
		t.Fatalf("exit %d\n%s", r.exit, r.shown())
	}
	contains(t, "stdout", r.out.String(), "resuming Build "+id)
	contains(t, "stdout", r.out.String(), "landed fixture ")
	eq(t, "requests", f.count(), requests)
	eq(t, "committed", e.gitOut("show", "HEAD:app.txt"), "reviewer repair")
	if now := e.result(id); !reflect.DeepEqual(now, original) {
		t.Fatal("the interrupted run's result changed")
	}
	child := e.otherRun(id)
	eq(t, "reviews", e.result(child)["reviews"], any(float64(1)))
	review := e.jsonFile(e.runPath(child, "review-1.json"))
	eq(t, "verdict", review["verdict"], any("approve"))
}

func TestAReopenedReviewersResetsPreserveTheUnresolvedBlockerAndCannotAuthorizeACommit(t *testing.T) {
	t.Parallel()
	// ExUnit: test/integration/build_boundaries_test.exs: reopened reviewer resets preserve the unresolved blocker and cannot authorize commit
	e := newEnv(t)
	f := e.prov
	f.then(landScript(f)...)
	blocker := finding("blocking", "Unresolved exact requirement")
	verdict := submit(f, "changes", blocker)
	f.then(verdict)
	start := e.head()
	a := e.reviewed()
	eq(t, "exit", a.exit, 1)
	id := e.onlyRun()
	for i := 0; i < 3; i++ {
		f.then(f.calls("write_file", map[string]any{"path": ".kogen/local/padding", "content": strings.Repeat("x", 190_000)}))
	}
	f.then(verdict)
	index := e.state()["index"]
	r := e.resumeReviewed(id)
	eq(t, "exit", r.exit, 1)
	contains(t, "stdout", r.out.String(), "review_blocked")
	eq(t, "head", e.head(), start)
	eq(t, "index", e.state()["index"], index)
	var reset map[string]any
	for _, req := range f.reviewRequests() {
		for _, it := range requestInput(req) {
			m, _ := it.(map[string]any)
			if s, ok := m["content"].(string); ok && strings.HasPrefix(s, "Local working-window reset\n") {
				reset = map[string]any{}
				if err := json.Unmarshal([]byte(strings.TrimPrefix(s, "Local working-window reset\n")), &reset); err != nil {
					t.Fatal(err)
				}
			}
		}
	}
	if reset == nil {
		t.Fatal("no reset reached the reviewer")
	}
	eq(t, "owner", reset["owner"], any("review"))
	findings := reset["findings"].([]any)
	if len(findings) != 1 || findings[0].(map[string]any)["message"] != "Unresolved exact requirement" {
		t.Fatalf("findings %v", findings)
	}
	child := e.otherRun(id)
	_, state := e.checkpoint(child)
	last := state["last_review"].(map[string]any)
	eq(t, "verdict", last["verdict"], any("changes"))
	eq(t, "stage", state["continuation"].(map[string]any)["stage"], any("review_verify"))
	if _, err := os.Stat(project.ApprovalPath(e.root, testSlug)); err != nil {
		t.Fatal("the approval was removed")
	}
}

func TestAResumedFittedReviewPinsItsSourceWhenTheConversationOutgrowsTheWindow(t *testing.T) {
	t.Parallel()
	// Intent review-refine-working-room: resume a fitted inline Review with room for investigation and final repair
	e := newEnv(t)
	f := e.prov
	f.then(f.calls("finish", map[string]any{"summary": "done"}), refused())
	a := e.reviewed()
	eq(t, "first exit", a.exit, 4)
	id := e.onlyRun()
	_, state := e.checkpoint(id)
	owner := state["working_context"].(map[string]any)["review"].(map[string]any)
	if owner["inline_material"] == nil || owner["source_tree"] == nil {
		t.Fatalf("the saved review context lacks its inline material: %v", owner)
	}
	for i := 0; i < 3; i++ {
		f.then(f.calls("write_file", map[string]any{"path": ".kogen/local/padding", "content": strings.Repeat("x", 190_000)}))
	}
	f.then(f.calls("read_file", map[string]any{"path": "app.txt"}))
	shared := readPinned(e, f)
	for i := 0; i < 40; i++ {
		f.then(shared)
	}
	r := e.resumeReviewed(id)
	if r.exit != 0 {
		t.Fatalf("exit %d\n%s\n%s", r.exit, r.shown(), r.errs.String())
	}
	parts, _ := filepath.Glob(filepath.Join(e.root, ".kogen/local/runs/*/review-source/*/*.json"))
	if len(parts) == 0 {
		t.Fatal("the inline source was never pinned after the resume")
	}
}

func TestAResumedFittedReviewOfALargerSourcePinsItAndDeliversIt(t *testing.T) {
	t.Parallel()
	// Intent review-refine-working-room: resume a fitted inline Review with room for investigation and final repair (suite parameters)
	e := newEnv(t)
	e.write("README.md", "# Fixture project\n"+strings.Repeat("r", 61000)+"\n")
	e.write("docs/development.md", strings.Repeat("d", 49000)+"\n")
	e.write("seed-knowledge.txt", strings.Repeat("k", 32000)+"\n")
	e.write("pad.txt", strings.Repeat("p", 22000))
	e.run("git", "add", "README.md", "docs/development.md", "seed-knowledge.txt", "pad.txt")
	e.run("git", "commit", "-qm", "Seed maintained documents")
	f := e.prov
	f.then(
		f.calls("shell", map[string]any{"command": "printf '\\nreview-edit\\n' >> README.md; printf '\\nreview-edit\\n' >> docs/development.md; cp seed-knowledge.txt knowledge_live.ex"}),
		f.calls("finish", map[string]any{"summary": "candidate complete"}),
		failure(503, "server_error", "local scripted overload"),
	)
	a := e.reviewed()
	if a.exit == 0 {
		t.Fatal("the first run should stop")
	}
	id := e.onlyRun()
	for n := 1; n <= 8; n++ {
		f.then(f.calls("read_file", map[string]any{"path": "pad.txt"}, "read_file", map[string]any{"path": "pad.txt"}, "read_file", map[string]any{"path": "pad.txt"}))
	}
	f.then(f.calls("read_file", map[string]any{"path": "pad.txt"}))
	shared := readPinned(e, f)
	for i := 0; i < 60; i++ {
		f.then(shared)
	}
	r := e.resumeReviewed(id)
	parts, _ := filepath.Glob(filepath.Join(e.root, ".kogen/local/runs/*/review-source/*/*.json"))
	if r.exit != 0 || len(parts) == 0 {
		t.Fatalf("exit %d, %d parts\n%s\n%s", r.exit, len(parts), r.shown(), r.errs.String())
	}
}

// reviewShapeCases covers the accepted set as well as shape and inner-validation failures.
func reviewShapeCases() []struct {
	args     string
	accepted bool
	problem  string
} {
	return []struct {
		args     string
		accepted bool
		problem  string
	}{
		{`{"verdict":"approve","findings":[]}`, true, ""},
		{`{"verdict":"approve","findings":[{"path":"app.txt","line":1,"severity":"note","message":"PRIVATE_REVIEW_MARKER"}]}`, true, ""},
		{`{"verdict":"changes","findings":[{"path":"app.txt","line":1,"severity":"blocking","message":"PRIVATE_REVIEW_MARKER"}]}`, true, ""},
		{`{"verdict":"approve","findings":"[]"}`, false, "submit_review needs verdict (approve or changes) and a findings list; findings must be a JSON array of objects but was a string"},
		{`{"verdict":"approve","findings":"[{\"path\":\"app.txt\",\"line\":1,\"severity\":\"note\",\"message\":\"PRIVATE_REVIEW_MARKER\"}]"}`, false, "submit_review needs verdict (approve or changes) and a findings list; findings must be a JSON array of objects but was a string"},
		{`{"verdict":"approve"}`, false, "submit_review needs verdict (approve or changes) and a findings list; findings must be a JSON array of objects but was missing"},
		{`{"verdict":"approve","findings":null}`, false, "submit_review needs verdict (approve or changes) and a findings list; findings must be a JSON array of objects but was null"},
		{`{"verdict":"approve","findings":{"private":"PRIVATE_REVIEW_MARKER"}}`, false, "submit_review needs verdict (approve or changes) and a findings list; findings must be a JSON array of objects but was an object"},
		{`{"verdict":"approve","findings":true}`, false, "submit_review needs verdict (approve or changes) and a findings list; findings must be a JSON array of objects but was a boolean"},
		{`{"verdict":"approve","findings":12345}`, false, "submit_review needs verdict (approve or changes) and a findings list; findings must be a JSON array of objects but was a number"},
		{`{"findings":[]}`, false, "submit_review needs verdict (approve or changes) and a findings list; verdict must be approve or changes but was missing"},
		{`{"verdict":null,"findings":[]}`, false, "submit_review needs verdict (approve or changes) and a findings list; verdict must be approve or changes but was null"},
		{`{"verdict":12345,"findings":[]}`, false, "submit_review needs verdict (approve or changes) and a findings list; verdict must be approve or changes but was a number"},
		{`{"verdict":false,"findings":[]}`, false, "submit_review needs verdict (approve or changes) and a findings list; verdict must be approve or changes but was a boolean"},
		{`{"verdict":{"private":"PRIVATE_REVIEW_MARKER"},"findings":[]}`, false, "submit_review needs verdict (approve or changes) and a findings list; verdict must be approve or changes but was an object"},
		{`{"verdict":["PRIVATE_REVIEW_MARKER"],"findings":[]}`, false, "submit_review needs verdict (approve or changes) and a findings list; verdict must be approve or changes but was an array"},
		{`{"verdict":"PRIVATE_REVIEW_MARKER","findings":[]}`, false, "submit_review needs verdict (approve or changes) and a findings list; verdict must be approve or changes but was a string with an unsupported value"},
		{`{}`, false, "submit_review needs verdict (approve or changes) and a findings list; verdict must be approve or changes but was missing; findings must be a JSON array of objects but was missing"},
		{`{"verdict":"PRIVATE_REVIEW_MARKER","findings":"PRIVATE_REVIEW_MARKER"}`, false, "submit_review needs verdict (approve or changes) and a findings list; verdict must be approve or changes but was a string with an unsupported value; findings must be a JSON array of objects but was a string"},
		{`{"verdict":"changes","findings":[]}`, false, "a changes verdict needs at least one blocking finding"},
		{`{"verdict":"approve","findings":[{"path":"app.txt","line":1,"severity":"blocking","message":"PRIVATE_REVIEW_MARKER"}]}`, false, "an approve verdict cannot have blocking findings"},
		{`{"verdict":"approve","findings":[{"path":"app.txt","line":1.5,"severity":"note","message":"PRIVATE_REVIEW_MARKER"}]}`, false, "each finding needs path (string), line (integer), severity (blocking or note) and message"},
	}
}

func decodeReviewArgs(t *testing.T, text string) map[string]any {
	t.Helper()
	var args map[string]any
	dec := json.NewDecoder(strings.NewReader(text))
	dec.UseNumber()
	if err := dec.Decode(&args); err != nil {
		t.Fatal(err)
	}
	return args
}

func TestReviewValidateAcceptanceSet(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "app.txt"), []byte("candidate"), 0600); err != nil {
		t.Fatal(err)
	}
	r := &reviewRun{b: &Attempt{Root: root}}
	for i, tc := range reviewShapeCases() {
		t.Run(fmt.Sprint(i), func(t *testing.T) {
			verdict, problems, err := r.validate(decodeReviewArgs(t, tc.args), nil)
			if err != nil {
				t.Fatal(err)
			}
			eq(t, "accepted", verdict != nil, tc.accepted)
			eq(t, "diagnostic", strings.Join(problems, "; "), tc.problem)
			if strings.Contains(strings.Join(problems, ""), "PRIVATE_REVIEW_MARKER") {
				t.Fatal("private value disclosed")
			}
		})
	}
}

// readThen reads the pinned parts in batches, then submits the verdict.
func readThen(f *fakeProvider, verdict string, fs ...map[string]any) handler {
	var parts []string
	next := 0
	return func(w http.ResponseWriter, r *http.Request) {
		if parts == nil {
			parts = catalogParts(reviewCatalog(f.t, f.reviewRequests()[0]))
		}
		if next >= len(parts) {
			submit(f, verdict, fs...)(w, r)
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

func TestChangesWhilePartsAreUnreadIsSentBackToRead(t *testing.T) {
	e := newEnv(t)
	f := e.prov
	f.then(f.calls("write_file", map[string]any{"path": "app.txt", "content": bigFile()}, "finish", map[string]any{"summary": "done"}))
	f.then(submit(f, "changes", finding("blocking", "the parts were not delivered")))
	reader := readThen(f, "approve")
	for i := 0; i < 30; i++ {
		f.then(reader)
	}
	a := e.reviewed()
	eq(t, "exit", a.exit, 0)
	reqs := f.reviewRequests()
	text := requestText(reqs[1])
	contains(t, "feedback", text, "invalid verdict:")
	contains(t, "feedback", text, "pinned part(s) unread; read them before a verdict; incomplete delivery is not a candidate defect; use read_file on ")
}

func TestAReviewerThatNeverReadsIsStopped(t *testing.T) {
	e := newEnv(t)
	f := e.prov
	f.then(f.calls("write_file", map[string]any{"path": "app.txt", "content": bigFile()}, "finish", map[string]any{"summary": "done"}))
	for i := 0; i < 40; i++ {
		f.then(submit(f, "changes", finding("blocking", "x")))
	}
	start := e.head()
	a := e.reviewed()
	eq(t, "exit", a.exit, 1)
	eq(t, "head", e.head(), start)
	// The first unread answer is the uncounted baseline; the next two, with an unread count
	// that does not fall, are an ordinary invalid answer and then the limit.
	eq(t, "review requests", len(f.reviewRequests()), 3)
	eq(t, "outcome", e.result(e.onlyRun())["outcome"], any("review_invalid"))
}

func TestChangesAfterEveryPartWasReadStaysBlocked(t *testing.T) {
	e := newEnv(t)
	f := e.prov
	f.then(f.calls("write_file", map[string]any{"path": "app.txt", "content": bigFile()}, "finish", map[string]any{"summary": "done"}))
	reader := readThen(f, "changes", finding("blocking", "real defect"))
	for i := 0; i < 30; i++ {
		f.then(reader)
	}
	a := e.reviewed()
	eq(t, "exit", a.exit, 1)
	contains(t, "stdout", a.out.String(), "review_blocked")
}

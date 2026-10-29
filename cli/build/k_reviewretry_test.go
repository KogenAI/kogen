package build

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// Tests of the retry of verdictless independent reviews (Intent k-reviewretry): the real
// Build, Resume, local Git and the scripted provider, never a mocked review result.

func prose(text string) handler {
	return sse(map[string]any{"type": "message", "id": "msg-1", "role": "assistant", "content": []any{map[string]any{"type": "output_text", "text": text}}})
}

func jsonOf(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}

// reviewEvents are the review events of a run in order: verdicts, valid and invalid.
func (e *env) reviewVerdicts(id string) []map[string]any { return eventsNamed(e.events(id), "review") }

func cacheKey(req map[string]any) string { k, _ := req["prompt_cache_key"].(string); return k }

// requestSansInput is the request without the conversation and the tool choice.
func requestSansInput(req map[string]any) string {
	c := map[string]any{}
	for k, v := range req {
		if k != "input" && k != "tool_choice" {
			c[k] = v
		}
	}
	return jsonOf(c)
}

var forcedSubmit = map[string]any{"type": "function", "name": "submit_review"}

func counters(ev map[string]any) [2]float64 {
	r, _ := ev["rejected_verdicts"].(float64)
	n, _ := ev["no_tool_reminders"].(float64)
	return [2]float64{r, n}
}

// TestKReviewRetryFreshConversation: a review that ends without a valid verdict, prose-only or
// rejected, gets exactly one fresh same-kind review of the unchanged green candidate, numbered
// as the next review, with the same material and rules and nothing of the invalid conversation
// or the builder's.
func TestKReviewRetryFreshConversation(t *testing.T) {
	bad := finding("blocking", "An approve verdict cannot contain a blocking finding.")
	for name, tc := range map[string]struct {
		first  func(f *fakeProvider) []handler
		reason string
		want   [2]float64
	}{
		"prose-only turns": {func(f *fakeProvider) []handler { return []handler{prose("All good."), prose("Still good.")} }, "no_tool_reminder_exhausted", [2]float64{0, 1}},
		"rejected verdicts": {func(f *fakeProvider) []handler {
			return []handler{submit(f, "approve", bad), submit(f, "approve", bad)}
		}, "rejected_verdict_exhausted", [2]float64{1, 0}},
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			e := newEnv(t)
			f := e.prov
			f.then(landScript(f)...)
			f.then(tc.first(f)...)
			f.then(submit(f, "approve", finding("note", "fine")))
			start := e.head()
			a := e.reviewed()
			if a.exit != 0 || a.err != nil {
				t.Fatalf("exit %d err %v\n%s", a.exit, a.err, a.shown())
			}
			id := e.onlyRun()
			eq(t, "commits", e.gitOut("rev-list", "--count", start+"..HEAD"), "1")
			eq(t, "committed", e.gitOut("show", "HEAD:app.txt"), "candidate")
			eq(t, "builder requests", f.count()-len(f.reviewRequests()), 1)

			reqs := f.reviewRequests()
			eq(t, "review requests", len(reqs), 3)
			// Review 2 is a fresh conversation: its own cache identity and one opening message,
			// with exactly the material, rules and tools review 1 was given.
			eq(t, "fresh conversation input", len(requestInput(reqs[2])), 1)
			eq(t, "same opening material", jsonOf(requestInput(reqs[2])[0]), jsonOf(requestInput(reqs[0])[0]))
			eq(t, "same rules", requestInstructions(reqs[2]), requestInstructions(reqs[0]))
			eq(t, "same tools", jsonOf(reqs[2]["tools"]), jsonOf(reqs[0]["tools"]))
			eq(t, "same request but the conversation", requestSansInput(reqs[2]), strings.ReplaceAll(requestSansInput(reqs[0]), cacheKey(reqs[0]), cacheKey(reqs[2])))
			if cacheKey(reqs[0]) == "" || cacheKey(reqs[0]) == cacheKey(reqs[2]) || cacheKey(reqs[0]) != cacheKey(reqs[1]) {
				t.Fatalf("cache identities %q %q %q", cacheKey(reqs[0]), cacheKey(reqs[1]), cacheKey(reqs[2]))
			}
			// Neither the builder's replay nor review 1's conversation reaches review 2.
			lacks(t, "review 2", requestText(reqs[2]), "function_call")
			lacks(t, "review 2", requestText(reqs[2]), "Not a valid verdict")
			lacks(t, "review 2", requestText(reqs[2]), "invalid verdict")

			// The run log: review 1 invalid with its reason and counters, review 2 approved.
			verdicts := e.reviewVerdicts(id)
			eq(t, "review events", len(verdicts), 2)
			eq(t, "review 1", verdicts[0]["review"], any(float64(1)))
			eq(t, "review 1 verdict", verdicts[0]["verdict"], any("invalid"))
			eq(t, "review 1 reason", verdicts[0]["reason"], any(tc.reason))
			eq(t, "review 1 counters", counters(verdicts[0]), tc.want)
			eq(t, "review 2", verdicts[1]["review"], any(float64(2)))
			eq(t, "review 2 verdict", verdicts[1]["verdict"], any("approve"))
			retries := eventsNamed(e.events(id), "review_retry")
			eq(t, "retry events", len(retries), 1)
			eq(t, "retry kind", retries[0]["kind"], any("automatic"))
			eq(t, "retry from", retries[0]["from_review"], any(float64(1)))
			eq(t, "retry to", retries[0]["review"], any(float64(2)))
			only := eventsNamed(e.events(id), "review_only")
			eq(t, "review-only boundary", len(only), 1)
			eq(t, "review-only eligible", only[0]["eligible"], any(true))
			eq(t, "review-only next", only[0]["next"], any("automatic"))

			res := e.result(id)
			eq(t, "reviews", res["reviews"], any(float64(2)))
			eq(t, "passes", res["passes"], any(float64(1)))
			if _, err := os.Stat(e.runPath(id, "review-1.json")); !os.IsNotExist(err) {
				t.Fatal("an invalid review has a review record")
			}
			approved := e.jsonFile(e.runPath(id, "review-2.json"))
			eq(t, "review-2 verdict", approved["verdict"], any("approve"))
			eq(t, "review-2 tree", approved["tree"], any(e.gitOut("rev-parse", "HEAD^{tree}")))
			// The durable lineage names review 1 and the spent automatic retry.
			_, state := e.checkpoint(id)
			rr, _ := state["review_retry"].(map[string]any)
			if rr == nil || rr["automatic"] != true || rr["tree"] != e.gitOut("rev-parse", "HEAD^{tree}") {
				t.Fatalf("review_retry %v", rr)
			}
			lineage := rr["invalid"].([]any)
			eq(t, "lineage", len(lineage), 1)
			eq(t, "lineage reason", lineage[0].(map[string]any)["reason"], any(tc.reason))
		})
	}
}

// allowanceKit is the helpers of TestKReviewRetrySeparateAllowances that its 232-part case,
// which lives in a file of its own, shares.
type allowanceKit struct {
	build  func(t *testing.T, content string) (*env, *fakeProvider)
	check  func(t *testing.T, e *env, f *fakeProvider, content string, parts, requests, forced int, wantAllowances []string) ([]map[string]any, []map[string]any)
	unread func(t *testing.T, req map[string]any, pattern string) int
	wanted func(events []map[string]any, why string, parts int) int
}

// heavyAllowanceCases are the subtests with hundreds of pinned parts, added by
// k_reviewretry_decrel_test.go outside the race detector's run.
var heavyAllowanceCases []func(t *testing.T, kit allowanceKit)

// pinned232 is a changed file whose review source pins exactly 232 source parts (the S-DECREL
// shape): Kogen carries the parts in native prefill messages that count only once a completed
// response follows them.
func pinned232() string { return strings.Repeat("0123456789abcdef-line\n", 30_800) }

// pinned113 pins 113 parts: still more than the native prefill of one request carries, at a
// fraction of the cost (every tool call and request rescans every part's custody).
func pinned113() string { return strings.Repeat("0123456789abcdef-line\n", 15_000) }

func reviewRetryToolOutputs(req map[string]any) []string {
	var out []string
	for _, raw := range requestInput(req) {
		if item, _ := raw.(map[string]any); item["type"] == "function_call_output" {
			if s, ok := item["output"].(string); ok {
				out = append(out, s)
			}
		}
	}
	return out
}

func prefillEvents(events []map[string]any) (all [][]float64) {
	for _, ev := range eventsNamed(events, "review_source_prefill") {
		var parts []float64
		for _, p := range ev["parts"].([]any) {
			parts = append(parts, p.(float64))
		}
		all = append(all, parts)
	}
	return all
}

func union(sets ...[]float64) map[float64]bool {
	u := map[float64]bool{}
	for _, s := range sets {
		for _, n := range s {
			u[n] = true
		}
	}
	return u
}

// allDelivered reports whether every pinned part of the review has reached the model by the
// time the response to req completes: in the request's own window (complete reads, native
// prefill) or in the delivery facts of its working-window reset.
func allDelivered(t *testing.T, req map[string]any) bool {
	t.Helper()
	known, _ := inWindow(req)
	for path := range prefilledParts(t, req) {
		known[path] = true
	}
	parts := pinnedOf(req)
	if reset := resetHandoff(t, req); reset != nil {
		if d, ok := reset["review_delivery"].(map[string]any); ok {
			if source, ok := d["source"].(map[string]any); ok && source["current"] == true {
				unread := map[int]bool{}
				for _, n := range source["unread"].([]any) {
					unread[int(n.(float64))] = true
				}
				for i, p := range parts {
					if !unread[i+1] {
						known[p] = true
					}
				}
			}
		}
	}
	for _, p := range parts {
		if !known[p] {
			return false
		}
	}
	return len(parts) > 0
}

// deliverThen is the reviewer that keeps working (it keeps searching with long queries, whose
// replayed arguments fill its working window, so that Kogen's native prefill delivers the pinned parts in
// window after window) until every pinned part has really been delivered; only then does it
// play the final handlers, one per request.
func deliverThen(f *fakeProvider, final ...handler) handler {
	step := 0
	return func(w http.ResponseWriter, r *http.Request) {
		reqs := f.reviewRequests()
		if allDelivered(f.t, reqs[len(reqs)-1]) && step < len(final) {
			step++
			final[step-1](w, r)
			return
		}
		// One call with a long argument: the replayed arguments fill the window, not tool outputs.
		f.calls("search_text", map[string]any{"query": strings.Repeat("x", 180_000)})(w, r)
	}
}

func repeatHandler(h handler, n int) []handler {
	out := make([]handler, n)
	for i := range out {
		out[i] = h
	}
	return out
}

// TestKReviewRetrySeparateAllowances: a rejected submit_review and a prose-only turn are sent
// back once each and independently, in either order, in one conversation; the unread-parts
// progress exemption stays; a second spending of either allowance ends only that allowance.
func TestKReviewRetrySeparateAllowances(t *testing.T) {
	build := func(t *testing.T, content string) (*env, *fakeProvider) {
		e := newEnv(t)
		f := e.prov
		f.then(f.calls("write_file", map[string]any{"path": "app.txt", "content": content}, "finish", map[string]any{"summary": "done"}))
		return e, f
	}
	// check is what both 232-part orders share: one review, one conversation, approval after
	// complete real delivery, both counters in the log and the actual unread rejections.
	check := func(t *testing.T, e *env, f *fakeProvider, content string, parts, requests, forced int, wantAllowances []string) (events []map[string]any, reqs []map[string]any) {
		t.Helper()
		a := e.reviewed()
		if a.exit != 0 || a.err != nil {
			t.Fatalf("exit %d err %v\n%s", a.exit, a.err, a.shown())
		}
		id := e.onlyRun()
		reqs = f.reviewRequests()
		if requests >= 0 {
			eq(t, "review requests", len(reqs), requests)
		}
		if forced < 0 {
			forced = len(reqs) - 1
		}
		eq(t, "pinned parts", len(catalogParts(reviewCatalog(t, reqs[0]))), parts)
		for i, req := range reqs {
			var want any = "auto"
			if i == forced {
				want = forcedSubmit
			}
			eq(t, "tool_choice of request "+itoa(i), req["tool_choice"], want)
			if cacheKey(req) != cacheKey(reqs[0]) || cacheKey(req) == "" {
				t.Fatalf("request %d left the conversation: %q vs %q", i, cacheKey(req), cacheKey(reqs[0]))
			}
		}
		events = e.events(id)
		eq(t, "reviews", e.result(id)["reviews"], any(float64(1)))
		eq(t, "retry events", len(eventsNamed(events, "review_retry")), 0)
		verdicts := eventsNamed(events, "review")
		eq(t, "verdict events", len(verdicts), 1)
		eq(t, "approved in review 1", verdicts[0]["verdict"], any("approve"))
		eq(t, "approved review", verdicts[0]["review"], any(float64(1)))
		var got []string
		for _, ev := range eventsNamed(events, "review_allowance") {
			got = append(got, ev["why"].(string)+":"+jsonOf(counters(ev)))
		}
		eq(t, "allowance log", got, wantAllowances)
		choice := eventsNamed(events, "review_tool_choice")
		eq(t, "tool choice events", len(choice), 1)
		eq(t, "selected mode", choice[0]["mode"], any("api_forced"))
		// The reviewer worked across local working windows, and approval came only after every
		// part was delivered by a complete read.
		if len(eventsNamed(events, "window_reset")) == 0 {
			t.Fatal("the conversation never left its first working window")
		}
		var material map[string]any
		for _, ev := range eventsNamed(events, "review_material") {
			material = ev
		}
		eq(t, "parts read", material["parts_read"], any(float64(parts)))
		eq(t, "committed", e.gitOut("show", "HEAD:app.txt")+"\n", content)
		return events, reqs
	}
	// unread is the count a rejection reported, and wanted what Kogen had actually delivered
	// when it was made: the parts of the prefill messages logged before that moment.
	unread := func(t *testing.T, req map[string]any, pattern string) int {
		t.Helper()
		re := regexp.MustCompile(pattern)
		for _, out := range reviewRetryToolOutputs(req) {
			if m := re.FindStringSubmatch(out); m != nil {
				var n int
				if _, err := fmt.Sscan(m[1], &n); err == nil {
					return n
				}
			}
		}
		t.Fatalf("no %q rejection in %v", pattern, reviewRetryToolOutputs(req))
		return 0
	}
	wanted := func(events []map[string]any, why string, parts int) int {
		var delivered []float64
		for _, ev := range events {
			if ev["event"] == "review_source_prefill" {
				for _, p := range ev["parts"].([]any) {
					delivered = append(delivered, p.(float64))
				}
			}
			if ev["event"] == "review_allowance" && ev["why"] == why {
				return parts - len(union(delivered))
			}
		}
		return -1
	}

	kit := allowanceKit{build, check, unread, wanted}
	if len(heavyAllowanceCases) == 0 {
		t.Log("the S-DECREL and fresh-review 113/232-part cases run without the race detector (k_reviewretry_decrel_test.go)")
	}
	for _, heavy := range heavyAllowanceCases {
		heavy(t, kit)
	}

	t.Run("a second spending ends only its own allowance", func(t *testing.T) {
		bad := finding("blocking", "An approve verdict cannot contain a blocking finding.")
		rejected := func(f *fakeProvider) handler { return submit(f, "approve", bad) }
		say := func(f *fakeProvider) handler { return prose("again") }
		type ending struct {
			script []func(f *fakeProvider) handler
			reason string
			want   [2]float64
		}
		// A Build holds two verdictless reviews (the first and its one fresh retry): each pair
		// of cases below is one Build, review 1 then review 2.
		for name, pair := range map[string][2]ending{
			"second rejected verdict, then second prose-only turn": {
				{[]func(*fakeProvider) handler{rejected, rejected}, "rejected_verdict_exhausted", [2]float64{1, 0}},
				{[]func(*fakeProvider) handler{say, say}, "no_tool_reminder_exhausted", [2]float64{0, 1}},
			},
			"rejected then prose then prose, and prose then rejected then rejected": {
				{[]func(*fakeProvider) handler{rejected, say, say}, "no_tool_reminder_exhausted", [2]float64{1, 1}},
				{[]func(*fakeProvider) handler{say, rejected, rejected}, "rejected_verdict_exhausted", [2]float64{1, 1}},
			},
		} {
			t.Run(name, func(t *testing.T) {
				t.Parallel()
				e := newEnv(t)
				f := e.prov
				f.then(landScript(f)...)
				total := 0
				for _, end := range pair {
					for _, step := range end.script {
						f.then(step(f))
						total++
					}
				}
				a := e.reviewed()
				wantStop(t, a, "candidate/review_invalid")
				id := e.onlyRun()
				verdicts := e.reviewVerdicts(id)
				eq(t, "review events", len(verdicts), 2)
				for i, end := range pair {
					eq(t, "reason of review "+itoa(i+1), verdicts[i]["reason"], any(end.reason))
					eq(t, "counters of review "+itoa(i+1), counters(verdicts[i]), end.want)
				}
				// Neither allowance was raised: each review took exactly its scripted requests.
				eq(t, "review requests", len(f.reviewRequests()), total)
			})
		}
	})
}

// anthropicReply answers a Messages request with the given content blocks.
func anthropicReply(blocks ...map[string]any) handler {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		frame := func(v map[string]any) { io.WriteString(w, "event: "+v["type"].(string)+"\ndata: "+jsonText(v)+"\n\n") }
		frame(map[string]any{"type": "message_start", "message": map[string]any{"id": "msg_fixture", "model": "claude-sonnet-5-5",
			"usage": map[string]any{"input_tokens": 7, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0}}})
		stop := "end_turn"
		for i, b := range blocks {
			if b["type"] == "tool_use" {
				stop = "tool_use"
			}
			frame(map[string]any{"type": "content_block_start", "index": i, "content_block": b})
			frame(map[string]any{"type": "content_block_stop", "index": i})
		}
		frame(map[string]any{"type": "message_delta", "delta": map[string]any{"stop_reason": stop}, "usage": map[string]any{"output_tokens": 4}})
		frame(map[string]any{"type": "message_stop"})
	}
}

// chatReply answers a Chat Completions request: prose, or one submit_review call.
func chatReply(text string, verdict map[string]any) handler {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		msg := map[string]any{"role": "assistant", "content": text}
		finish := "stop"
		if verdict != nil {
			args, _ := json.Marshal(verdict)
			msg = map[string]any{"role": "assistant", "content": nil, "tool_calls": []any{map[string]any{
				"id": "call_review", "type": "function", "function": map[string]any{"name": "submit_review", "arguments": string(args)}}}}
			finish = "tool_calls"
		}
		io.WriteString(w, jsonText(map[string]any{"id": "chatcmpl-fixture", "model": "kimi-k3", "choices": []any{map[string]any{"message": msg, "finish_reason": finish}},
			"usage": map[string]any{"prompt_tokens": 7, "completion_tokens": 4, "prompt_tokens_details": map[string]any{"cached_tokens": 0}, "completion_tokens_details": map[string]any{"reasoning_tokens": 0}}}))
	}
}

// reviewRole puts the review role on another provider and signs it in with a fixture key.
func (e *env) reviewRole(role string, credential string) {
	e.t.Helper()
	path := filepath.Join(e.root, ".kogen/project.yaml")
	b, err := os.ReadFile(path)
	if err != nil {
		e.t.Fatal(err)
	}
	review := regexp.MustCompile(`(?m)^  review:\n(    .*\n)+`)
	if !review.Match(b) {
		e.t.Fatalf("no review role in\n%s", b)
	}
	writeFile(e.t, path, string(review.ReplaceAll(b, []byte("  review: "+role+"\n"))), 0o644)
	e.run("git", "add", ".kogen/project.yaml")
	e.run("git", "commit", "-qm", "review role")
	e.approve()
	dir := filepath.Join(e.home, ".kogen", "credentials")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		e.t.Fatal(err)
	}
	key, _ := json.Marshal(map[string]any{"provider": credential, "api_key": "sk-FIXTURE-KEY"})
	if err := os.WriteFile(filepath.Join(dir, credential+".json"), key, 0o600); err != nil {
		e.t.Fatal(err)
	}
}

// requestsTo are the received requests that carry key (the conversation field of a wire).
func (f *fakeProvider) requestsWith(key string) []map[string]any {
	var out []map[string]any
	for _, r := range f.requests() {
		if _, ok := r[key]; ok {
			out = append(out, r)
		}
	}
	return out
}

func choiceEvents(e *env, id string) []map[string]any {
	return eventsNamed(e.events(id), "review_tool_choice")
}

// TestKReviewRetryReminderChoice: the request right after the no-tool reminder requires
// submit_review where the route supports named tool selection, and only that request; other
// routes keep today's reminder text with no forcing field; forcing never accepts a verdict
// that validation rejects and never earns a provider-refusal retry.
func TestKReviewRetryReminderChoice(t *testing.T) {
	bad := finding("blocking", "An approve verdict cannot contain a blocking finding.")

	t.Run("Responses route: reminder request only", func(t *testing.T) {
		t.Parallel()
		e := newEnv(t)
		f := e.prov
		f.then(landScript(f)...)
		f.then(prose("All good."), submit(f, "approve", bad), submit(f, "approve"))
		a := e.reviewed()
		eq(t, "exit", a.exit, 0)
		id := e.onlyRun()
		reqs := f.reviewRequests()
		eq(t, "review requests", len(reqs), 3)
		eq(t, "tool_choice", []any{reqs[0]["tool_choice"], reqs[1]["tool_choice"], reqs[2]["tool_choice"]}, []any{"auto", forcedSubmit, "auto"})
		// Forcing is only the tool choice: same model, effort, reasoning, tools and rules.
		for _, r := range reqs[1:] {
			eq(t, "same request but the conversation and the choice", requestSansInput(r), requestSansInput(reqs[0]))
		}
		for _, r := range reqs {
			if _, has := r["thinking"]; has {
				t.Fatal("thinking field on a Responses request")
			}
		}
		contains(t, "reminder", requestText(reqs[1]), "Not a valid verdict: the review ended without calling submit_review. Call submit_review.")
		// The forced verdict was still validated, rejected and counted apart from the reminder.
		contains(t, "forced verdict", requestText(reqs[2]), "invalid verdict:\\nan approve verdict cannot have blocking findings")
		choice := choiceEvents(e, id)
		eq(t, "choice events", len(choice), 1)
		eq(t, "mode", choice[0]["mode"], any("api_forced"))
		eq(t, "tool", choice[0]["tool"], any("submit_review"))
		eq(t, "counters at the reminder", counters(choice[0]), [2]float64{0, 1})
		var allowances []string
		for _, ev := range eventsNamed(e.events(id), "review_allowance") {
			allowances = append(allowances, ev["why"].(string)+":"+jsonOf(counters(ev)))
		}
		eq(t, "allowances", allowances, []string{"no_tool_turn:[0,1]", "rejected_verdict:[1,1]"})
		eq(t, "retry events", len(eventsNamed(e.events(id), "review_retry")), 0)
	})

	t.Run("a refusal of the forced request is reported, never retried", func(t *testing.T) {
		t.Parallel()
		e := newEnv(t)
		f := e.prov
		f.then(landScript(f)...)
		f.then(prose("All good."), failure(400, "invalid_request_error", "tool_choice is not supported"))
		start := e.head()
		a := e.reviewed()
		eq(t, "exit", a.exit, 4)
		contains(t, "stdout", a.shown(), "provider/refused")
		eq(t, "head", e.head(), start)
		reqs := f.reviewRequests()
		eq(t, "review requests: no second attempt, no fallback", len(reqs), 2)
		eq(t, "forced once", reqs[1]["tool_choice"], any(forcedSubmit))
		eq(t, "choice events", len(choiceEvents(e, e.onlyRun())), 1)
	})

	t.Run("Anthropic adaptive thinking: text-only reminder", func(t *testing.T) {
		t.Parallel()
		e := newEnv(t)
		e.reviewRole("{provider: anthropic, model: claude-sonnet-5-5, effort: high}", "anthropic")
		f := e.prov
		f.then(landScript(f)...)
		f.then(anthropicReply(map[string]any{"type": "text", "text": "All good."}),
			anthropicReply(map[string]any{"type": "tool_use", "id": "toolu_review", "name": "submit_review", "input": map[string]any{"verdict": "approve", "findings": []any{}}}))
		a := e.reviewed()
		if a.exit != 0 {
			t.Fatalf("exit %d\n%s\n%s", a.exit, a.shown(), a.errs)
		}
		reqs := f.requestsWith("messages")
		eq(t, "review requests", len(reqs), 2)
		for _, r := range reqs {
			eq(t, "tool_choice", r["tool_choice"], any(map[string]any{"type": "auto"}))
			eq(t, "thinking", r["thinking"], any(map[string]any{"type": "adaptive"}))
		}
		contains(t, "reminder text", jsonOf(reqs[1]["messages"]), "Not a valid verdict: the review ended without calling submit_review. Call submit_review.")
		choice := choiceEvents(e, e.onlyRun())
		eq(t, "choice events", len(choice), 1)
		eq(t, "mode", choice[0]["mode"], any("text_fallback"))
	})

	t.Run("OpenCode Go chat route: named function selection", func(t *testing.T) {
		t.Parallel()
		e := newEnv(t)
		e.reviewRole("{provider: opencode-go, model: kimi-k3, effort: high}", "opencode-go")
		f := e.prov
		f.then(landScript(f)...)
		f.then(chatReply("All good.", nil), chatReply("", map[string]any{"verdict": "approve", "findings": []any{}}))
		a := e.reviewed()
		if a.exit != 0 {
			t.Fatalf("exit %d\n%s\n%s", a.exit, a.shown(), a.errs)
		}
		reqs := f.requestsWith("messages")
		var chat []map[string]any
		for _, r := range reqs {
			if _, ok := r["reasoning_effort"]; ok {
				chat = append(chat, r)
			}
		}
		eq(t, "review requests", len(chat), 2)
		eq(t, "ordinary choice", chat[0]["tool_choice"], any("auto"))
		eq(t, "forced choice", chat[1]["tool_choice"], any(map[string]any{"type": "function", "function": map[string]any{"name": "submit_review"}}))
		eq(t, "same request but the conversation and the choice", requestSansMessages(chat[1]), requestSansMessages(chat[0]))
		choice := choiceEvents(e, e.onlyRun())
		eq(t, "choice events", len(choice), 1)
		eq(t, "mode", choice[0]["mode"], any("api_forced"))
	})
}

func requestSansMessages(req map[string]any) string {
	c := map[string]any{}
	for k, v := range req {
		if k != "messages" && k != "tool_choice" {
			c[k] = v
		}
	}
	return jsonOf(c)
}

package conformance

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"kogen-loop/api"
	"kogen-loop/loop"
	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen-loop/tools"
)

// rbProvider is a local Responses provider that answers the way a model does under request
// pressure: it reads one file per request, then finishes. A request without tools is a
// summarization request: it answers with a summary naming every FACT-nnn the request carries,
// so a fact survives only if it was in the exchanges given or in the summary given.
type rbProvider struct {
	t      *testing.T
	srv    *httptest.Server
	mu     sync.Mutex
	bodies []map[string]any
	normal int
	// plan answers the k-th conversation request (1-based) with response items.
	plan func(k int) []map[string]any
}

var rbFact = regexp.MustCompile(`FACT-\d{3}`)

func newRBProvider(t *testing.T, plan func(k int) []map[string]any) *rbProvider {
	t.Helper()
	p := &rbProvider{t: t, plan: plan}
	p.srv = httptest.NewServer(http.HandlerFunc(p.serve))
	t.Cleanup(p.srv.Close)
	return p
}

// fake lets the shared harness (runCLI, env) address this provider.
func (p *rbProvider) fake() *fakeProvider { return &fakeProvider{t: p.t, srv: p.srv} }

func (p *rbProvider) serve(w http.ResponseWriter, r *http.Request) {
	data, _ := io.ReadAll(r.Body)
	var body map[string]any
	json.Unmarshal(data, &body)
	if r.URL.Path != "/v1/responses" || body == nil {
		w.WriteHeader(400)
		fmt.Fprint(w, `{"error":{"message":"unexpected request","code":"invalid_request_error"}}`)
		return
	}
	p.mu.Lock()
	p.bodies = append(p.bodies, body)
	var items []map[string]any
	if tl, _ := body["tools"].([]any); len(tl) == 0 {
		in, _ := json.Marshal(body["input"])
		seen := map[string]bool{}
		var facts []string
		for _, f := range rbFact.FindAllString(string(in), -1) {
			if !seen[f] {
				seen[f] = true
				facts = append(facts, f)
			}
		}
		sort.Strings(facts)
		items = []map[string]any{message("SUMMARY of earlier work. Facts kept: " + strings.Join(facts, " ") + ". Checks passed so far; work remains.")}
	} else {
		p.normal++
		items = p.plan(p.normal)
	}
	p.mu.Unlock()
	w.Header().Set("Content-Type", "text/event-stream")
	for n, item := range items {
		d, _ := json.Marshal(map[string]any{"type": "response.output_item.done", "output_index": n, "item": item})
		fmt.Fprintf(w, "data: %s\n\n", d)
	}
	d, _ := json.Marshal(map[string]any{"type": "response.completed", "response": map[string]any{"status": "completed", "usage": fullUsage(10, 0, 5, 0)}})
	fmt.Fprintf(w, "data: %s\n\n", d)
}

func (p *rbProvider) all() []map[string]any {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]map[string]any(nil), p.bodies...)
}

func rbSummarizing(body map[string]any) bool {
	tl, _ := body["tools"].([]any)
	return len(tl) == 0
}

// conversation returns only the bodies of the conversation's own requests.
func (p *rbProvider) conversation() []map[string]any {
	var out []map[string]any
	for _, b := range p.all() {
		if !rbSummarizing(b) {
			out = append(out, b)
		}
	}
	return out
}

// rbReads is a plan: one read per request for n requests (every tenth is a parallel pair),
// then a finish that is only a claim.
func rbReads(n int) func(int) []map[string]any {
	return func(k int) []map[string]any {
		if k > n {
			return []map[string]any{call("fin", "finish", map[string]any{"summary": fmt.Sprintf("model claim: finished after %d exchanges", n)})}
		}
		items := []map[string]any{call(fmt.Sprintf("call-%03d", k), "read_file", map[string]any{"path": fmt.Sprintf("f%03d.txt", k)})}
		if k%10 == 0 {
			items = append(items, call(fmt.Sprintf("call-%03db", k), "read_file", map[string]any{"path": fmt.Sprintf("f%03d.txt", k)}))
		}
		return items
	}
}

// rbSeed writes n files of about size bytes, each opening with its fact.
func rbSeed(w *world, n, size int) {
	files := map[string]string{}
	for i := 1; i <= n; i++ {
		head := fmt.Sprintf("FACT-%03d decision and result of step %d. ", i, i)
		files[fmt.Sprintf("f%03d.txt", i)] = head + strings.Repeat("x", size-len(head))
	}
	w.seed(files)
}

func rbBodyBytes(t *testing.T, body map[string]any, role provider.Role) tools.Measurement {
	t.Helper()
	m, err := tools.Measure(body, role)
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func rbItems(body map[string]any) []map[string]any {
	var out []map[string]any
	in, _ := body["input"].([]any)
	for _, it := range in {
		if m, ok := it.(map[string]any); ok {
			out = append(out, m)
		}
	}
	return out
}

// rbPaired fails unless every call in the conversation request has its output after it, and
// every output its call.
func rbPaired(t *testing.T, body map[string]any, label string) {
	t.Helper()
	calls := map[string]int{}
	for i, it := range rbItems(body) {
		id, _ := it["call_id"].(string)
		switch it["type"] {
		case "function_call":
			calls[id] = i
		case "function_call_output":
			at, ok := calls[id]
			if !ok || at > i {
				t.Errorf("%s: output %s has no earlier call", label, id)
			}
			delete(calls, id)
		}
	}
	for id := range calls {
		t.Errorf("%s: call %s has no output", label, id)
	}
}

func rbUserContents(body map[string]any) []string {
	var out []string
	for _, it := range rbItems(body) {
		if it["role"] == "user" {
			s, _ := it["content"].(string)
			out = append(out, s)
		}
	}
	return out
}

func rbHasFacts(t *testing.T, body map[string]any, n int, label string) {
	t.Helper()
	in, _ := json.Marshal(body["input"])
	for i := 1; i <= n; i++ {
		if f := fmt.Sprintf("FACT-%03d", i); !strings.Contains(string(in), f) {
			t.Errorf("%s: %s did not survive", label, f)
			return
		}
	}
}

// rbSummaryOf is the condensed summary message of a conversation request, "" when none.
func rbSummaryOf(body map[string]any) string {
	for _, c := range rbUserContents(body) {
		if strings.HasPrefix(c, loop.CondensedHeader) {
			return c
		}
	}
	return ""
}

func TestRequestBudgetRetention(t *testing.T) {
	t.Parallel()
	const instructions = "RETENTION-INSTRUCTIONS: never lose a fact."
	const task = "TASK-ONE: read every file and keep its fact."
	const second = "TASK-TWO: a later user instruction that must stay verbatim."
	const first, many = 3, 120
	w := newWorld(t).signIn()
	rbSeed(w, many+first, 9000)
	// Round 1 reads three files and answers without a call; round 2 reads many more, then finishes.
	p := newRBProvider(t, func(k int) []map[string]any {
		switch {
		case k <= first:
			return rbReads(1 << 30)(k)
		case k == first+1:
			return []map[string]any{message("round one done")}
		}
		return rbReads(first + many)(k - 1)
	})
	f := p.fake()
	role := provider.Role{Provider: "chatgpt", Model: "fixture-model", Effort: "medium"}
	dir := filepath.Join(w.tmp, "session")
	newCfg := func(events *[]api.Event) loop.SessionConfig {
		return loop.SessionConfig{
			Root: w.root, Role: role, Instructions: instructions, Dir: dir,
			Client: provider.NewClient("kogen-loop test"), Session: sys.NewWith(w.env(f), w.root),
			Emit: func(e api.Event) { *events = append(*events, e) },
		}
	}
	var events []api.Event
	sess, err := loop.NewSession(newCfg(&events))
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	res, err := sess.Round(ctx, task)
	if err != nil || res.Ending != loop.EndNoCall {
		t.Fatalf("round 1: %v %v", res.Ending, err)
	}
	res, err = sess.Round(ctx, second)
	if err != nil || res.Ending != loop.EndTerminal || res.Terminal == nil || res.Terminal.Name != "finish" {
		t.Fatalf("round 2: %v %v", res.Ending, err)
	}

	var condensed []api.Event
	for _, e := range events {
		if e.Type == api.EventContextCondensed {
			condensed = append(condensed, e)
		}
		if e.Type == api.EventError {
			t.Errorf("error event %v", e.Fields)
		}
	}
	if len(condensed) < 2 {
		t.Fatalf("%d condensations; the pressure needs repeated condensation", len(condensed))
	}
	t.Logf("%d condensations", len(condensed))
	convo := p.conversation()
	for i, b := range convo {
		if !rbBodyBytes(t, b, role).Fits {
			t.Errorf("conversation request %d does not fit", i+1)
		}
		if b["instructions"] != instructions {
			t.Errorf("conversation request %d: instructions changed", i+1)
		}
		rbPaired(t, b, fmt.Sprintf("request %d", i+1))
	}
	for _, b := range p.all() {
		if !rbBodyBytes(t, b, role).Fits {
			t.Error("a summarization request does not fit")
		}
	}
	last := convo[len(convo)-1]
	users := rbUserContents(last)
	if len(users) < 3 || users[0] != task || users[1] != second || !strings.HasPrefix(users[2], loop.CondensedHeader) {
		t.Errorf("user messages of the last request: %q", users)
	}
	rbHasFacts(t, last, many+first, "last request")
	// The newest complete exchange is exact and the older ones are in the summary, not exact.
	in, _ := json.Marshal(last["input"])
	if !strings.Contains(string(in), fmt.Sprintf(`"call_id":"call-%03d"`, many+first)) || strings.Contains(string(in), `"call_id":"call-001"`) {
		t.Error("the last request keeps the wrong exchanges exact")
	}
	// The second summary builds on the first: its facts are all there although only the newest chunk was summarized again.
	if s := rbSummaryOf(last); !strings.Contains(s, "FACT-001") {
		t.Errorf("summary %q", s)
	}

	// The summary is retained in the transcript and survives resume.
	data, err := os.ReadFile(filepath.Join(dir, "session.json"))
	if err != nil || !strings.Contains(string(data), "Condensed earlier work") || !strings.Contains(string(data), "FACT-001") {
		t.Fatalf("transcript lacks the summary: %v", err)
	}
	var again []api.Event
	resumed, err := loop.ResumeSession(newCfg(&again))
	if err != nil {
		t.Fatal(err)
	}
	before := len(p.conversation())
	if res, err = resumed.Round(ctx, "continue"); err != nil || res.Ending != loop.EndTerminal {
		t.Fatalf("resume: %v %v", res.Ending, err)
	}
	after := p.conversation()
	if len(after) != before+1 {
		t.Fatalf("%d requests after resume", len(after)-before)
	}
	rb := after[before]
	if u := rbUserContents(rb); len(u) < 3 || u[0] != task || u[1] != second || rbSummaryOf(rb) == "" {
		t.Errorf("resumed request lost the task, instruction or summary: %q", u)
	}
	rbHasFacts(t, rb, many+first, "resumed request")
	rbPaired(t, rb, "resumed request")
}

// The feedback that answers a terminal call is a later user instruction: condensation keeps it,
// with the call it answers, exact instead of folding it into the summary.
func TestRequestBudgetKeepsTerminalFeedback(t *testing.T) {
	t.Parallel()
	const feedback = "FEEDBACK-TWO: review found a problem; fix it before finishing."
	const first, many = 3, 120
	w := newWorld(t).signIn()
	rbSeed(w, many+first, 9000)
	p := newRBProvider(t, func(k int) []map[string]any {
		switch {
		case k <= first:
			return rbReads(1 << 30)(k)
		case k == first+1:
			return []map[string]any{call("fin-1", "finish", map[string]any{"summary": "round one claim"})}
		}
		return rbReads(first + many)(k - 1)
	})
	role := provider.Role{Provider: "chatgpt", Model: "fixture-model", Effort: "medium"}
	var events []api.Event
	sess, err := loop.NewSession(loop.SessionConfig{
		Root: w.root, Role: role, Client: provider.NewClient("kogen-loop test"), Session: sys.NewWith(w.env(p.fake()), w.root),
		Emit: func(e api.Event) { events = append(events, e) },
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	if res, err := sess.Round(ctx, "TASK-ONE"); err != nil || res.Ending != loop.EndTerminal {
		t.Fatalf("round 1: %v %v", res.Ending, err)
	}
	if res, err := sess.Round(ctx, feedback); err != nil || res.Ending != loop.EndTerminal {
		t.Fatalf("round 2: %v %v", res.Ending, err)
	}
	condensed := 0
	for _, e := range events {
		if e.Type == api.EventContextCondensed {
			condensed++
		}
	}
	if condensed == 0 {
		t.Fatal("no condensation; the fixture needs pressure")
	}
	convo := p.conversation()
	last := convo[len(convo)-1]
	rbPaired(t, last, "last request")
	kept := false
	for _, it := range rbItems(last) {
		if it["type"] == "function_call_output" && it["call_id"] == "fin-1" && it["output"] == feedback {
			kept = true
		}
	}
	if !kept {
		t.Error("the feedback answering the terminal call was not kept exact")
	}
	rbHasFacts(t, last, many+first, "last request")
}

func TestRequestBudgetCLI(t *testing.T) {
	t.Parallel()
	const instructions = "CLI-INSTRUCTIONS: keep every fact and call tools until finished."
	const prompt = "CLI-TASK: read all the files in order and keep their facts."
	role := provider.Role{Provider: "chatgpt", Model: "fixture-model", Effort: "medium"}
	for _, c := range []struct{ exchanges, size int }{{54, 12000}, {73, 9000}, {177, 6000}} {
		t.Run(fmt.Sprintf("%d exchanges", c.exchanges), func(t *testing.T) {
			t.Parallel()
			w := newWorld(t).signIn()
			rbSeed(w, c.exchanges, c.size)
			p := newRBProvider(t, rbReads(c.exchanges))
			r := runCLI(t, w, p.fake(), w.task(map[string]any{"prompt": prompt, "instructions": instructions}))
			if r.exit != 0 || len(r.all("error")) != 0 || strings.Contains(strings.Join(r.lines, "\n"), "context_budget_exceeded") {
				t.Fatalf("exit %d, errors %v, stderr %s", r.exit, r.all("error"), r.stderr)
			}
			ended := r.first("round.ended")
			if ended == nil || ended["ending"] != "terminal" || ended["terminal_tool"] != "finish" || !strings.Contains(fmt.Sprint(ended["claim"]), "model claim") {
				t.Fatalf("round.ended %v", ended)
			}

			condensed := r.all("context.condensed")
			if len(condensed) == 0 {
				t.Fatal("no context.condensed disclosure")
			}
			convo := p.conversation()
			if len(convo) != c.exchanges+1 {
				t.Errorf("%d conversation requests, want %d", len(convo), c.exchanges+1)
			}
			t.Logf("%d condensations", len(condensed))
			summaryRequests := 0
			for _, b := range p.all() {
				if !rbBodyBytes(t, b, role).Fits {
					t.Error("a request over the ceiling was sent")
				}
				if rbSummarizing(b) {
					summaryRequests++
				}
			}
			disclosed := 0
			for _, e := range condensed {
				disclosed += int(e["requests"].(float64))
				if e["condensed_exchanges"].(float64) < 1 || e["kept_exchanges"].(float64) < 1 || e["bytes_after"].(float64) > e["limit"].(float64) || e["bytes_before"].(float64) <= e["limit"].(float64) {
					t.Errorf("disclosure %v", e)
				}
			}
			if disclosed != summaryRequests {
				t.Errorf("disclosed %d summarization requests, the provider saw %d", disclosed, summaryRequests)
			}
			for i, b := range convo {
				if b["instructions"] != instructions {
					t.Errorf("request %d: instructions changed", i+1)
				}
				if u := rbUserContents(b); len(u) == 0 || u[0] != prompt {
					t.Errorf("request %d: the task is not the first message", i+1)
				}
				rbPaired(t, b, fmt.Sprintf("request %d", i+1))
			}
			last := convo[len(convo)-1]
			rbHasFacts(t, last, c.exchanges, "last request")
			if rbSummaryOf(last) == "" {
				t.Error("the last request has no summary")
			}
			in, _ := json.Marshal(last["input"])
			if !strings.Contains(string(in), fmt.Sprintf(`"call_id":"call-%03d"`, c.exchanges)) {
				t.Error("the newest exchange is not exact")
			}

			// Every condensation comes before the response of the request it belongs to, and the
			// run keeps calling tools after the last one.
			for i, ev := range r.events {
				if ev["type"] != "context.condensed" {
					continue
				}
				for _, next := range r.events[i+1:] {
					if next["type"] == "request.started" {
						t.Errorf("a new request started before the condensed request was answered (condensation %v)", ev["seq"])
					}
					if next["type"] == "response" {
						if next["n"] != ev["n"] {
							t.Errorf("condensation for request %v precedes response %v", ev["n"], next["n"])
						}
						break
					}
				}
			}
			lastSeq := condensed[len(condensed)-1]["seq"].(float64)
			after := 0
			for _, ev := range r.events {
				if ev["type"] == "tool.call" && ev["seq"].(float64) > lastSeq {
					after++
				}
			}
			if after == 0 {
				t.Error("no tool call followed the last condensation")
			}
		})
	}
}

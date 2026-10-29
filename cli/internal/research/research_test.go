package research

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen-loop/tools"
)

// recorder is a local Anthropic endpoint that keeps the raw request bodies and refuses them.
type recorder struct {
	mu     sync.Mutex
	bodies [][]byte
}

func newRecorder(t *testing.T) (*recorder, *sys.Session) {
	t.Helper()
	r := &recorder{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		body, _ := io.ReadAll(req.Body)
		r.mu.Lock()
		r.bodies = append(r.bodies, body)
		r.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(400)
		io.WriteString(w, `{"error":{"code":"invalid_request_error","message":"refused","type":"invalid_request_error"}}`)
	}))
	t.Cleanup(srv.Close)
	home := t.TempDir()
	dir := filepath.Join(home, ".kogen", "credentials")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	key, _ := json.Marshal(map[string]any{"provider": "anthropic", "api_key": "sk-ant-FIXTURE-KEY"})
	if err := os.WriteFile(filepath.Join(dir, "anthropic.json"), key, 0o600); err != nil {
		t.Fatal(err)
	}
	env := []string{"PATH=" + os.Getenv("PATH"), "HOME=" + home, "KOGEN_PROVIDER_URL=" + srv.URL, "KOGEN_AUTH_URL=" + srv.URL}
	return r, sys.NewWith(env, t.TempDir())
}

func (r *recorder) count() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.bodies)
}

func set(t *testing.T, s Settings) {
	t.Helper()
	old := Current
	Current = s
	t.Cleanup(func() { Current = old })
}

var role = provider.Role{Provider: "anthropic", Model: "claude-sonnet-5-5", Effort: "high"}

func request(pad int) provider.Request {
	return Request(provider.Request{
		Role: role, Instructions: "policy", CacheID: "research-test",
		Input: []any{
			map[string]any{"role": "user", "content": "authority"},
			map[string]any{"role": "user", "content": strings.Repeat("a", pad)},
		},
	})
}

func newClient() *provider.Client {
	c := provider.NewClient("kogen dev+12345678 (test)")
	c.Sleep = func(context.Context, time.Duration) error { return nil }
	return c
}

// TestMeasuredIsSent holds that what Kogen measures is what it sends: the same request with the
// authority marker, and the configured lower ceiling applied inclusively before transport.
func TestMeasuredIsSent(t *testing.T) {
	set(t, Settings{AuthorityBoundary: new(int), InputBudgetBytes: 65536})
	rec, sess := newRecorder(t)
	client := newClient()
	measure := func(pad int) int {
		m, err := Measure(client.Body(request(pad)), role)
		if err != nil {
			t.Fatal(err)
		}
		return m.RenderedBytes
	}
	base := measure(0)
	if m, _ := Measure(client.Body(request(0)), role); m.InputBudgetBytes != 65536 {
		t.Fatalf("ceiling %d", m.InputBudgetBytes)
	}
	pad := 65536 - base

	// Exactly at the ceiling fits and the bytes on the wire are the measured bytes.
	if _, err := Respond(context.Background(), client, sess, request(pad), nil); err == nil {
		t.Fatal("the stub endpoint accepted a request")
	}
	if rec.count() != 1 {
		t.Fatalf("%d requests sent", rec.count())
	}
	if got, want := len(rec.bodies[0]), measure(pad); got != want || got != 65536 {
		t.Fatalf("sent %d bytes, measured %d, ceiling 65536", got, want)
	}
	if !strings.Contains(string(rec.bodies[0]), `"cache_control"`) {
		t.Fatal("no breakpoints in the request sent")
	}
	var sent map[string]any
	if err := json.Unmarshal(rec.bodies[0], &sent); err != nil {
		t.Fatal(err)
	}
	first := sent["messages"].([]any)[0].(map[string]any)["content"].([]any)[0].(map[string]any)
	if first["cache_control"] == nil {
		t.Fatalf("the authority block is not marked: %v", first)
	}

	// One byte over is refused before any transport, naming the lower ceiling.
	_, err := Respond(context.Background(), client, sess, request(pad+1), nil)
	e, ok := sys.AsError(err)
	if !ok || e.Reason != "context_budget_exceeded" || !strings.Contains(e.Detail, "65537 bytes exceeds 65536") {
		t.Fatalf("error %v", err)
	}
	if rec.count() != 1 {
		t.Fatalf("an over-ceiling request was sent: %d requests", rec.count())
	}
}

// TestZeroSendsTheLibrarysRequest holds that zero settings add nothing to the library's call.
func TestZeroSendsTheLibrarysRequest(t *testing.T) {
	rec, sess := newRecorder(t)
	req := request(70000)
	if _, err := newClient().Respond(context.Background(), sess, req, nil); err == nil {
		t.Fatal("the stub accepted a request")
	}
	if _, err := Respond(context.Background(), newClient(), sess, req, nil); err == nil {
		t.Fatal("the stub accepted a request")
	}
	if rec.count() != 2 || string(rec.bodies[0]) != string(rec.bodies[1]) {
		t.Fatalf("%d requests; bodies equal: %v", rec.count(), rec.count() == 2 && string(rec.bodies[0]) == string(rec.bodies[1]))
	}
}

// TestApplyReachesEveryOption holds that each setting lands on the loop option it names.
func TestApplyReachesEveryOption(t *testing.T) {
	boundary := 3
	set(t, Settings{
		Tools:             ToolSettings{ResultBound: 2000, ResultHead: 500},
		Documentation:     DocumentationSettings{ResultBound: 4096, BodyBound: 8192},
		Client:            ClientSettings{ResponseBudget: time.Minute},
		InputBudgetBytes:  100000,
		AuthorityBoundary: &boundary,
	})
	tl := ApplyTools(&tools.Tools{Documentation: tools.Documentation{UserAgent: "kogen/x"}})
	if tl.ResultBound != 2000 || tl.ResultHead != 500 || tl.Documentation.ResultBound != 4096 || tl.Documentation.BodyBound != 8192 || tl.Documentation.UserAgent != "kogen/x" {
		t.Fatalf("%+v", tl)
	}
	if c := ApplyClient(provider.NewClient("")); c.ResponseBudget != time.Minute {
		t.Fatalf("response budget %s", c.ResponseBudget)
	}
	r := Request(provider.Request{})
	if r.AuthorityBoundary == nil || *r.AuthorityBoundary != 3 || r.AuthorityBoundary == &boundary {
		t.Fatalf("authority %v", r.AuthorityBoundary)
	}
	if InputBudget() != 100000 {
		t.Fatalf("input budget %d", InputBudget())
	}
	if got := CutText(strings.Repeat("a", 5000)); len(got) > 2000 || !strings.Contains(got, "bytes omitted") {
		t.Fatalf("cut %d bytes", len(got))
	}
}

// TestProductionResponseBudgetDefault holds the one tunable line: ten minutes, with every other
// setting still the loop's own default.
func TestProductionResponseBudgetDefault(t *testing.T) {
	if want := (Settings{Client: ClientSettings{ResponseBudget: 10 * time.Minute}}); !reflect.DeepEqual(Current, want) {
		t.Fatalf("Current = %+v", Current)
	}
	if err := Validate(context.Background(), nil); err != nil {
		t.Fatal(err)
	}
	if e := BudgetEvent(); e["event"] != "response_budget" || e["budget"] != "10 minutes" || e["budget_ms"] != int64(600000) || len(e) != 3 {
		t.Fatalf("event %v", e)
	}
	set(t, Settings{})
	if BudgetEvent() != nil {
		t.Fatal("a zero budget is recorded")
	}
}

// TestApplyClientKeepsALowerBudget holds that a client built with a lower budget is not raised
// to the configured one.
func TestApplyClientKeepsALowerBudget(t *testing.T) {
	for _, c := range []struct{ client, want time.Duration }{
		{0, 10 * time.Minute}, {time.Second, time.Second}, {10 * time.Minute, 10 * time.Minute}, {30 * time.Minute, 10 * time.Minute},
	} {
		client := provider.NewClient("")
		client.ResponseBudget = c.client
		if got := ApplyClient(client).ResponseBudget; got != c.want {
			t.Errorf("client %s: %s, want %s", c.client, got, c.want)
		}
	}
}

// TestRespondNamesTheTenMinuteExpiry holds that only the configured ten-minute expiry is
// renamed: other durations, classes and reasons pass unchanged.
func TestRespondNamesTheTenMinuteExpiry(t *testing.T) {
	expired := func(budget time.Duration, e *sys.Error) error { return diagnostic(e, budget) }
	got := expired(10*time.Minute, sys.Fail("provider", "unavailable", "SuperGrok response wait exceeded 10m0s", 4)).(*sys.Error)
	if got.Class != "provider" || got.Reason != "unavailable" || got.Exit != 4 || got.Detail != "SuperGrok response wait exceeded 10 minutes" {
		t.Fatalf("%+v", got)
	}
	for _, c := range []struct {
		budget time.Duration
		err    *sys.Error
	}{
		{10 * time.Minute, sys.Fail("provider", "unavailable", "ChatGPT response wait exceeded 2s", 4)},
		{10 * time.Minute, sys.Fail("provider", "unavailable", "ChatGPT response wait exceeded 30 minutes", 4)},
		{10 * time.Minute, sys.Fail("provider", "refused", "ChatGPT response wait exceeded 10m0s", 4)},
		{10 * time.Minute, sys.Fail("provider", "unavailable", "the response wait exceeded 10m0s of patience", 4)},
		{time.Second, sys.Fail("provider", "unavailable", "ChatGPT response wait exceeded 1s", 4)},
		{5 * time.Minute, sys.Fail("provider", "unavailable", "ChatGPT response wait exceeded 5m0s", 4)},
	} {
		if err := expired(c.budget, c.err); err != error(c.err) {
			t.Errorf("%q was changed: %v", c.err.Detail, err)
		}
	}
	if diagnostic(nil, 10*time.Minute) != nil {
		t.Error("nil became an error")
	}
}

// TestRespondExpiryEndsUnavailableNamingTenMinutes runs a real client whose clock passes ten
// minutes while the provider stalls.
func TestRespondExpiryEndsUnavailableNamingTenMinutes(t *testing.T) {
	var mu sync.Mutex
	now := time.Now()
	clock := func() time.Time { mu.Lock(); defer mu.Unlock(); return now }
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		w.(http.Flusher).Flush()
		mu.Lock()
		now = now.Add(10*time.Minute + time.Second)
		mu.Unlock()
		panic(http.ErrAbortHandler)
	}))
	defer srv.Close()
	home := t.TempDir()
	dir := filepath.Join(home, ".kogen", "credentials")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	key, _ := json.Marshal(map[string]any{"provider": "anthropic", "api_key": "sk-ant-FIXTURE-KEY"})
	if err := os.WriteFile(filepath.Join(dir, "anthropic.json"), key, 0o600); err != nil {
		t.Fatal(err)
	}
	s := sys.NewWith([]string{"PATH=" + os.Getenv("PATH"), "HOME=" + home, "KOGEN_PROVIDER_URL=" + srv.URL, "KOGEN_AUTH_URL=" + srv.URL}, t.TempDir())
	c := ApplyClient(newClient())
	c.Now = clock
	_, err := Respond(context.Background(), c, s, request(10), nil)
	e, ok := sys.AsError(err)
	if !ok || e.Class != "provider" || e.Reason != "unavailable" || e.Exit != 4 || !strings.HasSuffix(e.Detail, "response wait exceeded 10 minutes") {
		t.Fatalf("err %v", err)
	}
}

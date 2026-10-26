package provider

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"kogen-loop/sys"
)

// recorded is one request the fake server saw.
type recorded struct {
	Method, Path string
	Header       http.Header
	Body         []byte
	JSON         map[string]any // provider requests
	Form         url.Values     // token and device requests
}

type handler func(w http.ResponseWriter, r *http.Request)

// fake serves a scripted provider (/v1/responses) and a scripted authorization server
// (token and device endpoints). Past the end of a script it answers 400.
type fake struct {
	t        *testing.T
	srv      *httptest.Server
	mu       sync.Mutex
	prov     []recorded
	auth     []recorded
	provNext int
	authNext int
	provSeq  []handler
	authSeq  []handler
	authAll  handler // when set, answers every auth request
}

func newFake(t *testing.T, provider ...handler) *fake {
	f := &fake{t: t, provSeq: provider}
	f.srv = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fake) authScript(h ...handler) *fake { f.authSeq = h; return f }

func (f *fake) serve(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	rec := recorded{Method: r.Method, Path: r.URL.Path, Header: r.Header.Clone(), Body: body}
	var h handler
	f.mu.Lock()
	if r.URL.Path == "/v1/responses" {
		if v, err := decodeJSON(body); err == nil {
			rec.JSON, _ = v.(map[string]any)
		}
		f.prov = append(f.prov, rec)
		if f.provNext < len(f.provSeq) {
			h = f.provSeq[f.provNext]
		}
		f.provNext++
	} else {
		rec.Form, _ = url.ParseQuery(string(body))
		f.auth = append(f.auth, rec)
		switch {
		case f.authAll != nil:
			h = f.authAll
		case f.authNext < len(f.authSeq):
			h = f.authSeq[f.authNext]
		}
		f.authNext++
	}
	f.mu.Unlock()
	if h == nil {
		if r.URL.Path == "/v1/responses" {
			jsonAnswer(400, map[string]any{"error": map[string]any{"message": "scripted provider refusal", "code": "invalid_request_error"}})(w, r)
		} else {
			jsonAnswer(400, map[string]any{})(w, r)
		}
		return
	}
	h(w, r)
}

func (f *fake) requests() []recorded {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]recorded(nil), f.prov...)
}

func (f *fake) authRequests() []recorded {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]recorded(nil), f.auth...)
}

func jsonAnswer(status int, body any) handler {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-Request-Id", "req-fixture")
		w.WriteHeader(status)
		w.Write(mustEncode(body))
	}
}

func rawAnswer(status int, body string) handler {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Request-Id", "req-fixture")
		w.WriteHeader(status)
		io.WriteString(w, body)
	}
}

func frame(ev any) string { return "data: " + string(mustEncode(ev)) + "\n\n" }

// events answers 200 with the given SSE events and closes the stream.
func events(evs ...any) handler {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("X-Request-Id", "req-fixture")
		for _, e := range evs {
			io.WriteString(w, frame(e))
		}
	}
}

// openEvents sends the events and then keeps the stream open until the client closes it,
// signalling opened and closed.
func openEvents(opened, closed chan struct{}, evs ...any) handler {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("X-Request-Id", "req-fixture")
		for _, e := range evs {
			io.WriteString(w, frame(e))
		}
		w.(http.Flusher).Flush()
		close(opened)
		select {
		case <-r.Context().Done():
		case <-time.After(5 * time.Second):
		}
		close(closed)
	}
}

func rawStream(body string) handler {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, body)
	}
}

func done(response any) map[string]any {
	return map[string]any{"type": "response.completed", "response": response}
}

func itemDone(i int, item any) map[string]any {
	return map[string]any{"type": "response.output_item.done", "output_index": int64(i), "item": item}
}

func tool() map[string]any {
	return map[string]any{"type": "function_call", "call_id": "call", "name": "write_file", "arguments": "{}"}
}

func with(m map[string]any, kv ...any) map[string]any {
	out := map[string]any{}
	for k, v := range m {
		out[k] = v
	}
	for i := 0; i < len(kv); i += 2 {
		out[kv[i].(string)] = kv[i+1]
	}
	return out
}

// textAnswer is a completed answer with one assistant message and usage.
func textAnswer(txt string) handler {
	item := map[string]any{"type": "message", "id": "message", "role": "assistant", "content": []any{map[string]any{"type": "output_text", "text": txt, "annotations": []any{}}}}
	return events(itemDone(0, item), done(map[string]any{"usage": map[string]any{
		"input_tokens": int64(1), "input_tokens_details": map[string]any{"cached_tokens": int64(0)},
		"output_tokens": int64(1), "output_tokens_details": map[string]any{"reasoning_tokens": int64(0)}}}))
}

func httpFail(status int, code, message string) handler {
	return jsonAnswer(status, map[string]any{"error": map[string]any{"code": code, "message": message, "type": "invalid_request_error"}})
}

// clock is a fake clock whose Sleep advances it without waiting.
type clock struct {
	mu     sync.Mutex
	t      time.Time
	sleeps []time.Duration
}

func newClock() *clock { return &clock{t: time.Now()} }

func (c *clock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *clock) Sleep(ctx context.Context, d time.Duration) error {
	if d == RedirectWait {
		// The sign-in's overall wait is a timer, not a pause: it ends only when the context does.
		<-ctx.Done()
		return ctx.Err()
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	c.mu.Lock()
	c.t = c.t.Add(d)
	c.sleeps = append(c.sleeps, d)
	c.mu.Unlock()
	return nil
}

func (c *clock) slept() []time.Duration {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]time.Duration(nil), c.sleeps...)
}

// observer collects attempt records.
type observer struct {
	mu   sync.Mutex
	recs []map[string]any
}

func (o *observer) Attempt(r map[string]any) {
	o.mu.Lock()
	o.recs = append(o.recs, r)
	o.mu.Unlock()
}

func (o *observer) records() []map[string]any {
	o.mu.Lock()
	defer o.mu.Unlock()
	return append([]map[string]any(nil), o.recs...)
}

// env is one test's world: a temp HOME, a fake clock and a client wired to the fake.
type env struct {
	t    *testing.T
	home string
	clk  *clock
	c    *Client
	s    *sys.Session
	f    *fake
	out  *strings.Builder
	errs *strings.Builder
}

func newEnv(t *testing.T, f *fake) *env {
	t.Helper()
	home := t.TempDir()
	clk := newClock()
	e := &env{t: t, home: home, clk: clk, f: f, out: &strings.Builder{}, errs: &strings.Builder{}}
	e.c = &Client{Now: clk.Now, Sleep: clk.Sleep, Cache: NewCache(nil), Version: "kogen dev+12345678 (test)"}
	vars := []string{"HOME=" + home, "PATH=" + os.Getenv("PATH")}
	if f != nil {
		vars = append(vars, "KOGEN_PROVIDER_URL="+f.srv.URL, "KOGEN_AUTH_URL="+f.srv.URL)
	}
	e.s = sys.NewWith(vars, home)
	e.s.Stdout, e.s.Stderr = e.out, e.errs
	return e
}

// realClock makes the client use the system clock and real sleeps.
func (e *env) realClock() *env { e.c.Now, e.c.Sleep = nil, nil; return e }

func (e *env) credPath(name string) string {
	return filepath.Join(e.home, ".kogen", "credentials", name+".json")
}

// saveCreds writes a credentials file as JSON text.
func (e *env) saveCreds(name string, c map[string]any) {
	e.t.Helper()
	p := e.credPath(name)
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		e.t.Fatal(err)
	}
	if err := os.WriteFile(p, mustEncode(c), 0o600); err != nil {
		e.t.Fatal(err)
	}
}

func (e *env) chatgptCreds(mods ...any) map[string]any {
	return with(map[string]any{
		"client_id": "oaiapp_fixture", "access_token": "fake-access-token", "refresh_token": "fake-refresh-token",
		"expires_at": e.clk.Now().Unix() + 3600,
	}, mods...)
}

func (e *env) supergrokCreds(mods ...any) map[string]any {
	return with(map[string]any{
		"client_id": "synthetic-client", "referrer": "kogen", "access_token": "synthetic-access",
		"refresh_token": "synthetic-refresh", "expires_at": e.clk.Now().Unix() + 3600, "scope": "api:access",
	}, mods...)
}

func (e *env) readCreds(name string) map[string]any {
	e.t.Helper()
	data, err := os.ReadFile(e.credPath(name))
	if err != nil {
		e.t.Fatal(err)
	}
	v, err := decodeJSON(data)
	if err != nil {
		e.t.Fatal(err)
	}
	return v.(map[string]any)
}

var (
	fixtureRole = Role{Model: "fixture", Effort: "medium"}
	grokRole    = Role{Provider: "supergrok", Model: "grok-4.7", Effort: "low"}
)

func (e *env) respond(req Request) (*Response, error) {
	e.t.Helper()
	if req.Role == (Role{}) {
		req.Role = fixtureRole
	}
	if req.Instructions == "" {
		req.Instructions = "fixture"
	}
	return e.c.Respond(context.Background(), e.s, req, nil)
}

func mustErr(t *testing.T, err error) *sys.Error {
	t.Helper()
	e, ok := sys.AsError(err)
	if !ok {
		t.Fatalf("error %v (%T) is not a *sys.Error", err, err)
	}
	return e
}

func jsonOf(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

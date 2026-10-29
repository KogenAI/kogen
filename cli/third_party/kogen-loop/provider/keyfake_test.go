package provider

import (
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"

	"kogen-loop/sys"
)

const testKey = "SYNTHETIC_API_KEY_0001"

// keyFake serves a scripted OpenCode Go or Anthropic route at any path. Past the end of
// the script it answers 400.
type keyFake struct {
	t    *testing.T
	srv  *httptest.Server
	mu   sync.Mutex
	reqs []recorded
	seq  []handler
	next int
}

func newKeyFake(t *testing.T, h ...handler) *keyFake { return newKeyFakeTLS(t, false, h...) }

// newKeyFakeTLS is newKeyFake over HTTPS (a local certificate; use f.srv.Client()) when tls is set.
func newKeyFakeTLS(t *testing.T, tls bool, h ...handler) *keyFake {
	f := &keyFake{t: t, seq: h}
	start := httptest.NewServer
	if tls {
		start = httptest.NewTLSServer
	}
	f.srv = start(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		rec := recorded{Method: r.Method, Path: r.URL.Path, Header: r.Header.Clone(), Body: body}
		if v, err := decodeJSON(body); err == nil {
			rec.JSON, _ = v.(map[string]any)
		}
		var h handler
		f.mu.Lock()
		f.reqs = append(f.reqs, rec)
		if f.next < len(f.seq) {
			h = f.seq[f.next]
		}
		f.next++
		f.mu.Unlock()
		if h == nil {
			jsonAnswer(400, map[string]any{"error": map[string]any{"message": "scripted provider refusal"}})(w, r)
			return
		}
		h(w, r)
	}))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *keyFake) requests() []recorded {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]recorded(nil), f.reqs...)
}

// keyEnv is a test world with a saved key for the provider and the fake as its route.
func keyEnv(t *testing.T, name string, h ...handler) (*env, *keyFake) {
	t.Helper()
	f := newKeyFake(t, h...)
	e := newEnv(t, nil)
	e.s = sys.NewWith([]string{"HOME=" + e.home, "PATH=" + os.Getenv("PATH"), "KOGEN_PROVIDER_URL=" + f.srv.URL}, e.home)
	e.s.Stdout, e.s.Stderr = e.out, e.errs
	e.saveCreds(name, map[string]any{"provider": name, "api_key": testKey})
	return e, f
}

// sse is a Messages stream: each event as `event: <type>` and its JSON.
func sse(evs ...map[string]any) string {
	var b strings.Builder
	for _, e := range evs {
		b.WriteString("event: " + e["type"].(string) + "\ndata: " + string(mustEncode(e)) + "\n\n")
	}
	return b.String()
}

func sseAnswer(evs ...map[string]any) handler {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Request-Id", "req_anthropic_fixture")
		io.WriteString(w, sse(evs...))
	}
}

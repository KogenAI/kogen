package provider

import (
	"bytes"
	"context"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"sync"
	"testing"

	"kogen-loop/sys"
)

// L-CRED-ORIGIN: a saved openai-compatible key belongs to the origin it was logged in at.
// All worlds are fixture homes and local servers; no real credential or network is used.

const originKey = "SYNTHETIC_ORIGIN_KEY_0001"

// noNetwork is a transport that records every request and can reach nothing.
type noNetwork struct {
	mu   sync.Mutex
	reqs []*http.Request
}

func (n *noNetwork) RoundTrip(r *http.Request) (*http.Response, error) {
	n.mu.Lock()
	n.reqs = append(n.reqs, r)
	n.mu.Unlock()
	return nil, errors.New("network unavailable in this test")
}

func (n *noNetwork) count() int {
	n.mu.Lock()
	defer n.mu.Unlock()
	return len(n.reqs)
}

// originWorld is a fixture home whose client can only use the given transport.
func originWorld(t *testing.T, rt http.RoundTripper) *env {
	t.Helper()
	e := newEnv(t, nil)
	e.s = sys.NewWith([]string{"HOME=" + e.home, "PATH=" + os.Getenv("PATH")}, e.home)
	e.s.Stdout, e.s.Stderr = e.out, e.errs
	if rt != nil {
		e.c.HTTP = &http.Client{Transport: rt}
	}
	return e
}

func (e *env) originLogin(baseURL, key string) error {
	e.c.Input = &Input{Reader: strings.NewReader(key + "\n")}
	return e.c.LoginWithBaseURL(context.Background(), e.s, "openai-compatible", baseURL, nil)
}

func (e *env) originRespond(baseURL string) (*Response, error) {
	role := Role{Provider: "openai-compatible", Model: "m", Effort: "default", BaseURL: baseURL}
	return e.c.Respond(context.Background(), e.s, Request{Role: role, Instructions: "p", Input: user("x"), Scope: "s"}, nil)
}

func credBytes(t *testing.T, e *env) []byte { return credFile(t, e, "openai-compatible") }

func credFile(t *testing.T, e *env, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(e.credPath(name))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func noSecret(t *testing.T, err error, secrets ...string) {
	t.Helper()
	text := err.Error()
	if se, ok := sys.AsError(err); ok {
		text += se.Render()
	}
	for _, s := range secrets {
		if strings.Contains(text, s) {
			t.Fatalf("diagnostic carries a secret: %q", text)
		}
	}
}

func TestLCredOriginLogin(t *testing.T) {
	e := originWorld(t, nil)
	if err := e.originLogin("HTTPS://Models.Example:443/v1/x?q=1#frag", originKey); err != nil {
		t.Fatal(err)
	}
	if e.out.String() != "openai-compatible: key saved (not verified)\n" {
		t.Fatalf("%q", e.out.String())
	}
	c := e.readCreds("openai-compatible")
	if len(c) != 3 || c["provider"] != "openai-compatible" || c["api_key"] != originKey || c["origin"] != "https://models.example" {
		t.Fatalf("%v", c)
	}
	for path, mode := range map[string]os.FileMode{e.credPath("openai-compatible"): 0o600, e.home + "/.kogen/credentials": 0o700} {
		if info, err := os.Stat(path); err != nil || info.Mode().Perm() != mode {
			t.Fatalf("%s %v %v", path, info, err)
		}
	}
	// Non-default ports stay part of the origin; IPv6 literals keep their brackets.
	for in, want := range map[string]string{
		"https://models.example:8443/v1": "https://models.example:8443",
		"https://[::1]:8443":             "https://[::1]:8443",
		"https://[::1]":                  "https://[::1]",
		"https://api.models.example/":    "https://api.models.example",
	} {
		if err := e.originLogin(in, originKey); err != nil {
			t.Fatal(err)
		}
		if got := e.readCreds("openai-compatible")["origin"]; got != want {
			t.Errorf("%s saved %v, want %s", in, got, want)
		}
	}

	// A login without a URL, an empty or an unusable one saves nothing and keeps the bytes.
	before := credBytes(t, e)
	for _, url := range []string{"", "models.example", "ftp://models.example", "https://", "https://[bad"} {
		if err := e.originLogin(url, "other-key"); err == nil || mustErr(t, err).Reason != "login_failed" {
			t.Fatalf("%q: %v", url, err)
		}
	}
	e.c.Input = &Input{Reader: strings.NewReader("other-key\n")}
	err := e.c.Login(context.Background(), e.s, "openai-compatible", nil)
	if se := mustErr(t, err); se.Reason != "login_failed" || !strings.Contains(se.Detail, "LoginWithBaseURL") {
		t.Fatalf("%v", err)
	}
	noSecret(t, err, "other-key")
	if !bytes.Equal(credBytes(t, e), before) {
		t.Fatal("a refused login changed the saved credential")
	}
	fresh := originWorld(t, nil)
	fresh.c.Input = &Input{Reader: strings.NewReader("k\n")}
	if err := fresh.c.Login(context.Background(), fresh.s, "openai-compatible", nil); err == nil {
		t.Fatal("a URL-less login saved a key")
	}
	if _, err := os.Stat(fresh.credPath("openai-compatible")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("an unbound key was saved: %v", err)
	}

	// Other providers keep their format, with Login and with LoginWithBaseURL (URL ignored).
	for name, call := range map[string]func(*env) error{
		"opencode-go": func(o *env) error {
			return o.c.Login(context.Background(), o.s, "opencode-go", nil)
		},
		"anthropic": func(o *env) error {
			return o.c.LoginWithBaseURL(context.Background(), o.s, "anthropic", "http://ignored.example/v1", nil)
		},
	} {
		o := originWorld(t, nil)
		o.c.Input = &Input{Reader: strings.NewReader("sk-" + name + "\n")}
		if err := call(o); err != nil {
			t.Fatal(err)
		}
		if got := string(credFile(t, o, name)); got != string(mustEncode(map[string]any{"provider": name, "api_key": "sk-" + name})) {
			t.Errorf("%s: %s", name, got)
		}
	}
}

func TestLCredOriginMismatch(t *testing.T) {
	a := newKeyFakeTLS(t, true, jsonAnswer(200, goText("a")))
	b := newKeyFakeTLS(t, true, jsonAnswer(200, goText("b")))
	e := originWorld(t, nil)
	e.c.HTTP = a.srv.Client()
	if err := e.originLogin(a.srv.URL+"/v1", originKey); err != nil {
		t.Fatal(err)
	}
	before := credBytes(t, e)
	aOrigin := a.srv.URL
	au, _ := url.Parse(a.srv.URL)
	_, port, _ := net.SplitHostPort(au.Host)

	rec := &noNetwork{}
	// Every destination must be refused before any transport, naming both origins.
	cases := map[string]string{
		"other port":        b.srv.URL + "/v1",
		"attacker host":     "https://collector.attacker.invalid/v1",
		"other host":        "https://localhost:" + port + "/v1",
		"other scheme":      "http://127.0.0.1:" + port + "/v1",
		"subdomain":         "https://sub.127.0.0.1.example/v1",
		"default port":      "https://127.0.0.1/v1",
		"attacker + path":   "https://collector.attacker.invalid/v1/chat",
		"attacker upper":    "HTTPS://COLLECTOR.ATTACKER.INVALID:443",
		"userinfo trick":    "https://127.0.0.1:" + port + "@collector.attacker.invalid/v1",
		"saved at attacker": "https://collector.attacker.invalid:" + port + "/v1",
	}
	for name, dest := range cases {
		e.c.HTTP = &http.Client{Transport: rec}
		_, err := e.originRespond(dest)
		if err == nil {
			t.Fatalf("%s: a saved key was used at %s", name, dest)
		}
		se := mustErr(t, err)
		destOrigin, oerr := originOf(dest)
		if oerr != nil {
			t.Fatal(oerr)
		}
		if se.Class != "provider" || !strings.Contains(se.Detail, aOrigin) || !strings.Contains(se.Detail, destOrigin) {
			t.Errorf("%s: error does not name both origins (%s, %s): %v", name, aOrigin, destOrigin, err)
		}
		noSecret(t, err, originKey)
	}
	if rec.count() != 0 {
		t.Fatalf("%d requests left for a mismatched origin", rec.count())
	}
	if n := len(b.requests()); n != 0 {
		t.Fatalf("the other TLS server saw %d requests", n)
	}
	for _, r := range b.requests() {
		if r.Header.Get("Authorization") != "" {
			t.Fatal("key sent to the other origin")
		}
	}
	if len(a.requests()) != 0 {
		t.Fatalf("the saved origin saw requests from refused calls")
	}
	if !bytes.Equal(credBytes(t, e), before) {
		t.Fatal("a mismatch changed the saved credential")
	}
	// The same key still works at its own origin afterwards.
	e.c.HTTP = a.srv.Client()
	if _, err := e.originRespond(a.srv.URL + "/v1"); err != nil {
		t.Fatal(err)
	}
	if got := a.requests()[0].Header.Get("Authorization"); got != "Bearer "+originKey {
		t.Fatalf("%q", got)
	}
}

func TestLCredOriginMatch(t *testing.T) {
	a := newKeyFakeTLS(t, true, jsonAnswer(200, goText("first")), jsonAnswer(200, goText("second")), jsonAnswer(200, goText("third")))
	e := originWorld(t, nil)
	e.c.HTTP = a.srv.Client()
	if err := e.originLogin(a.srv.URL+"/v1", originKey); err != nil {
		t.Fatal(err)
	}
	for i, path := range []string{"/v1", "/other/prefix/", ""} {
		resp, err := e.originRespond(a.srv.URL + path)
		if err != nil {
			t.Fatalf("%q: %v", path, err)
		}
		if resp == nil || !strings.Contains(string(mustEncode(resp.Items)), []string{"first", "second", "third"}[i]) {
			t.Fatalf("%q: %+v", path, resp)
		}
	}
	for i, r := range a.requests() {
		if r.Method != "POST" || !strings.HasSuffix(r.Path, "/chat/completions") || r.Header.Get("Authorization") != "Bearer "+originKey {
			t.Fatalf("request %d: %s %s %q", i, r.Method, r.Path, r.Header.Get("Authorization"))
		}
	}

	// Equivalent spellings of one origin: scheme and host case, and the default port.
	seen := &recordingServer{}
	w := originWorld(t, seen)
	if err := w.originLogin("https://Models.Example:443/v1", originKey); err != nil {
		t.Fatal(err)
	}
	for _, dest := range []string{"https://models.example/api", "HTTPS://MODELS.EXAMPLE:443/v1/", "https://models.example:443", "https://models.example:0443"} {
		if _, err := w.originRespond(dest); err != nil {
			t.Fatalf("%s: %v", dest, err)
		}
	}
	if len(seen.auth) != 4 {
		t.Fatalf("%d requests", len(seen.auth))
	}
	for _, got := range seen.auth {
		if got != "Bearer "+originKey {
			t.Fatalf("%q", got)
		}
	}
}

// recordingServer answers every request with a chat answer and records its Authorization.
type recordingServer struct {
	auth []string
}

func (s *recordingServer) RoundTrip(r *http.Request) (*http.Response, error) {
	s.auth = append(s.auth, r.Header.Get("Authorization"))
	rec := httptest.NewRecorder()
	jsonAnswer(200, goText("ok"))(rec, r)
	return rec.Result(), nil
}

func TestLCredOriginLegacy(t *testing.T) {
	tls := newKeyFakeTLS(t, true, jsonAnswer(200, goText("no")))
	plain := newKeyFake(t, jsonAnswer(200, goText("no")))
	rec := &noNetwork{}
	for name, dest := range map[string]string{
		"https":    tls.srv.URL + "/v1",
		"loopback": plain.srv.URL + "/v1",
		"remote":   "https://models.example/v1",
	} {
		e := originWorld(t, nil)
		e.saveCreds("openai-compatible", map[string]any{"provider": "openai-compatible", "api_key": originKey})
		before := credBytes(t, e)
		e.c.HTTP = tls.srv.Client()
		if name == "remote" {
			e.c.HTTP = &http.Client{Transport: rec}
		}
		_, err := e.originRespond(dest)
		if err == nil {
			t.Fatalf("%s: an unbound key was used", name)
		}
		se := mustErr(t, err)
		if se.Class != "provider" || se.Reason != "login" || !strings.Contains(se.Detail, "log in again") {
			t.Errorf("%s: %v", name, err)
		}
		noSecret(t, err, originKey)
		if !bytes.Equal(credBytes(t, e), before) {
			t.Errorf("%s: credential changed", name)
		}
		if got := Status(e.home)[len(Catalog())-1]; got != "openai-compatible: saved key has no origin; log in again" {
			t.Errorf("status %q", got)
		}
	}
	if len(tls.requests())+len(plain.requests())+rec.count() != 0 {
		t.Fatal("a request was sent with a legacy key")
	}
}

func TestLCredOriginPlaintext(t *testing.T) {
	// Keyless loopback over HTTP works: localhost, IPv4 and IPv6 literals.
	v4 := newKeyFake(t, jsonAnswer(200, goText("v4")), jsonAnswer(200, goText("localhost")))
	e := originWorld(t, nil)
	if _, err := e.originRespond(v4.srv.URL + "/v1"); err != nil {
		t.Fatal(err)
	}
	_, port, _ := net.SplitHostPort(strings.TrimPrefix(v4.srv.URL, "http://"))
	if _, err := e.originRespond("http://LocalHost:" + port + "/v1"); err != nil {
		t.Fatal(err)
	}
	for _, r := range v4.requests() {
		if r.Header.Get("Authorization") != "" {
			t.Fatal("keyless request carried Authorization")
		}
	}
	if l, err := net.Listen("tcp6", "[::1]:0"); err == nil {
		v6 := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			jsonAnswer(200, goText("v6"))(w, r)
		}))
		v6.Listener.Close()
		v6.Listener = l
		v6.Start()
		defer v6.Close()
		if _, err := e.originRespond(v6.URL + "/v1"); err != nil {
			t.Fatal(err)
		}
	} else {
		t.Log("no IPv6 loopback here:", err)
	}
	// An invalid saved origin must not echo credential-like userinfo in diagnostics.
	bad := originWorld(t, &noNetwork{})
	bad.saveCreds("openai-compatible", map[string]any{"provider": "openai-compatible", "api_key": originKey, "origin": "https://" + originKey + "@"})
	_, badErr := bad.originRespond("https://models.example/v1")
	if badErr == nil {
		t.Fatal("invalid saved origin accepted")
	}
	noSecret(t, badErr, originKey)

	// HTTPS keyless use anywhere stays supported.
	tls := newKeyFakeTLS(t, true, jsonAnswer(200, goText("tls")))
	e.c.HTTP = tls.srv.Client()
	if _, err := e.originRespond(tls.srv.URL); err != nil {
		t.Fatal(err)
	}

	// Plain HTTP to anything else is refused before the network; names are not resolved.
	rec := &noNetwork{}
	e.c.HTTP = &http.Client{Transport: rec}
	for _, dest := range []string{
		"http://models.example/v1", "http://10.0.0.5:8080/v1", "http://localhost.attacker.invalid/v1",
		"http://127.0.0.1.attacker.invalid/v1", "http://0.0.0.0:8080", "http://[2001:db8::1]/v1",
	} {
		_, err := e.originRespond(dest)
		if err == nil || mustErr(t, err).Reason != "refused" || !strings.Contains(err.Error(), "HTTP") {
			t.Fatalf("%s: %v", dest, err)
		}
	}
	if rec.count() != 0 {
		t.Fatalf("%d requests for refused plaintext", rec.count())
	}

	// A saved key is never sent over HTTP, loopback included: bound to HTTPS, or hand-edited to HTTP.
	for name, origin := range map[string]string{"https origin": "https://127.0.0.1:" + port, "http origin": v4.srv.URL} {
		k := originWorld(t, nil)
		k.saveCreds("openai-compatible", map[string]any{"provider": "openai-compatible", "api_key": originKey, "origin": origin})
		before := len(v4.requests())
		_, err := k.originRespond(v4.srv.URL + "/v1")
		if err == nil {
			t.Fatalf("%s: a saved key was used over HTTP", name)
		}
		noSecret(t, err, originKey)
		if len(v4.requests()) != before {
			t.Fatalf("%s: request sent", name)
		}
	}

	// An HTTP key login is refused without touching the prior credential or reading the key.
	l := originWorld(t, nil)
	if err := l.originLogin("https://models.example/v1", originKey); err != nil {
		t.Fatal(err)
	}
	prior := credBytes(t, l)
	input := strings.NewReader("new-secret\n")
	l.c.Input = &Input{Reader: input}
	err := l.c.LoginWithBaseURL(context.Background(), l.s, "openai-compatible", v4.srv.URL+"/v1", nil)
	if err == nil || mustErr(t, err).Reason != "login_failed" || !strings.Contains(err.Error(), "HTTPS") {
		t.Fatalf("%v", err)
	}
	noSecret(t, err, "new-secret", originKey)
	if !bytes.Equal(credBytes(t, l), prior) || input.Len() == 0 {
		t.Fatal("an HTTP login changed the credential or consumed the key")
	}
	// And with nothing saved, no file appears.
	n := originWorld(t, nil)
	if err := n.originLogin("http://localhost:1/v1", "k"); err == nil {
		t.Fatal("HTTP login accepted")
	}
	if _, err := os.Stat(n.credPath("openai-compatible")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("%v", err)
	}
}

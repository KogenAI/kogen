package provider

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"kogen-loop/sys"
)

func jwt(claims map[string]any) string {
	return "unused." + base64.RawURLEncoding.EncodeToString(mustEncode(claims)) + ".unused"
}

// browser plays the user's browser and the authorization server for a ChatGPT sign-in.
type browser struct {
	t              *testing.T
	mu             sync.Mutex
	urls           []string
	states         []string
	nonce          string
	clientID       string // issued by the "sign-in"; "" omits it from the redirect
	email          string
	scope          string
	sendWrongState int
	redirectError  string
	idClaims       func(nonce string) map[string]any
}

func newBrowser(t *testing.T) *browser {
	return &browser{t: t, clientID: "oaiapp_issued", email: "user@example.com", scope: "openid profile email offline_access chatgpt.tokens.use.direct"}
}

func (b *browser) redirect(authURL string) (url.Values, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.urls = append(b.urls, authURL)
	u, err := url.Parse(authURL)
	if err != nil {
		return nil, err
	}
	q := u.Query()
	b.nonce = q.Get("nonce")
	if b.sendWrongState > 0 {
		b.sendWrongState--
		return url.Values{"state": {"wrong"}, "code": {"stolen"}}, nil
	}
	if b.redirectError != "" {
		v := url.Values{"state": {q.Get("state")}, "error": {b.redirectError}}
		if b.redirectError == "access_denied" {
			v.Set("error_description", "the user denied access")
		}
		return v, nil
	}
	v := url.Values{"state": {q.Get("state")}, "code": {"AUTH-CODE-SECRET"}}
	if b.clientID != "" {
		v.Set("client_id", b.clientID)
	}
	return v, nil
}

func (b *browser) tokens() handler {
	return func(w http.ResponseWriter, r *http.Request) {
		b.mu.Lock()
		claims := map[string]any{"nonce": b.nonce, "email": b.email}
		if b.idClaims != nil {
			claims = b.idClaims(b.nonce)
		}
		scope := b.scope
		b.mu.Unlock()
		jsonAnswer(200, map[string]any{"access_token": "ACCESS-SECRET", "refresh_token": "REFRESH-SECRET", "expires_in": int64(3600), "scope": scope, "id_token": jwt(claims)})(w, r)
	}
}

func login(e *env, name string, redirect RedirectFunc) error {
	return e.c.Login(context.Background(), e.s, name, redirect)
}

// features/08-chatgpt: browser login, private credentials and the status command (GPT-2/3/4).
func TestChatGPTBrowserLogin(t *testing.T) {
	old := syscall.Umask(0o022)
	defer syscall.Umask(old)
	br := newBrowser(t)
	f := newFake(t).authScript(br.tokens())
	e := newEnv(t, f)
	if err := login(e, "chatgpt", br.redirect); err != nil {
		t.Fatal(err)
	}
	if len(br.urls) != 1 {
		t.Fatal(len(br.urls))
	}
	lines := strings.Split(e.out.String(), "\n")
	if len(lines) != 4 || lines[0] != "Continue with ChatGPT" || lines[1] != br.urls[0] || lines[2] != "chatgpt signed in (user@example.com)" || lines[3] != "" {
		t.Fatalf("stdout = %q", e.out.String())
	}
	u, _ := url.Parse(br.urls[0])
	if !strings.HasPrefix(br.urls[0], f.srv.URL+"/api/accounts/authorize?") {
		t.Fatalf("url = %s", br.urls[0])
	}
	q := u.Query()
	hostID, _ := os.ReadFile(hostIDPath(e.home))
	want := map[string]string{
		"client_id": "dynamic_agent_client", "agent_name_hint": "Kogen", "ext_agent_host_id": strings.TrimSpace(string(hostID)),
		"response_type": "code", "redirect_uri": "http://127.0.0.1:1455/auth/callback",
		"scope":    "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
		"resource": "https://api.openai.com/v1", "code_challenge_method": "S256",
	}
	for k, v := range want {
		if q.Get(k) != v {
			t.Errorf("%s = %q, want %q", k, q.Get(k), v)
		}
	}
	if len(q) != len(want)+3 || q.Get("state") == "" || q.Get("nonce") == "" || !strings.HasPrefix(string(hostID), "urn:uuid:") {
		t.Fatalf("query = %v", q)
	}
	// PKCE S256: the challenge is the hash of the verifier sent with the code.
	auth := f.authRequests()
	if len(auth) != 1 || auth[0].Path != "/api/accounts/oauth/token" {
		t.Fatalf("auth = %+v", auth)
	}
	form := auth[0].Form
	sum := sha256.Sum256([]byte(form.Get("code_verifier")))
	if base64.RawURLEncoding.EncodeToString(sum[:]) != q.Get("code_challenge") {
		t.Fatal("PKCE challenge does not match the verifier")
	}
	for k, v := range map[string]string{"grant_type": "authorization_code", "client_id": "oaiapp_issued", "code": "AUTH-CODE-SECRET", "redirect_uri": "http://127.0.0.1:1455/auth/callback", "resource": "https://api.openai.com/v1"} {
		if form.Get(k) != v {
			t.Errorf("exchange %s = %q", k, form.Get(k))
		}
	}
	saved := e.readCreds("chatgpt")
	if saved["client_id"] != "oaiapp_issued" || saved["access_token"] != "ACCESS-SECRET" || saved["refresh_token"] != "REFRESH-SECRET" || saved["email"] != "user@example.com" ||
		saved["scope"] != br.scope || saved["expires_at"] != e.clk.Now().Unix()+3600 || len(saved) != 6 {
		t.Fatalf("saved = %v", saved)
	}
	if st, _ := os.Stat(e.credPath("chatgpt")); st.Mode().Perm() != 0o600 {
		t.Fatal("mode")
	}
	if got := Status(e.home)[0]; got != "chatgpt: signed in (user@example.com)" {
		t.Fatal(got)
	}
	mustNotExist(t, lockFile(e, "chatgpt"))
	// GPT-10: no token or code on stdout or stderr.
	for _, s := range []string{"ACCESS-SECRET", "REFRESH-SECRET", "AUTH-CODE-SECRET"} {
		if strings.Contains(e.out.String()+e.errs.String(), s) {
			t.Errorf("%s printed", s)
		}
	}

	// A second login reuses the issued client and registers nothing.
	br2 := newBrowser(t)
	br2.clientID = ""
	f.authSeq, f.authNext, f.authAll = []handler{br2.tokens()}, 0, nil
	e.out.Reset()
	if err := login(e, "chatgpt", br2.redirect); err != nil {
		t.Fatal(err)
	}
	q2, _ := url.Parse(br2.urls[0])
	if q2.Query().Get("client_id") != "oaiapp_issued" || q2.Query().Get("agent_name_hint") != "" || q2.Query().Get("ext_agent_host_id") != "" {
		t.Fatalf("second url = %s", br2.urls[0])
	}
}

// features/08-chatgpt: a redirect with the wrong state is ignored and the right one succeeds.
func TestChatGPTLoginIgnoresRedirectWithWrongState(t *testing.T) {
	br := newBrowser(t)
	br.sendWrongState = 2
	f := newFake(t).authScript(br.tokens())
	e := newEnv(t, f)
	if err := login(e, "chatgpt", br.redirect); err != nil {
		t.Fatal(err)
	}
	if len(br.urls) != 3 || strings.Count(e.errs.String(), "kogen: ignored a sign-in redirect with the wrong state\n") != 2 {
		t.Fatalf("%d redirects, stderr %q", len(br.urls), e.errs.String())
	}
	if len(f.authRequests()) != 1 || !strings.Contains(e.out.String(), "chatgpt signed in (user@example.com)") {
		t.Fatal("login did not complete")
	}
}

// features/08-chatgpt: a login without plan usage granted keeps nothing.
func TestChatGPTLoginWithoutPlanUsageKeepsNothing(t *testing.T) {
	br := newBrowser(t)
	br.scope = "openid profile email offline_access"
	f := newFake(t).authScript(br.tokens())
	e := newEnv(t, f)
	err := login(e, "chatgpt", br.redirect)
	se := mustErr(t, err)
	if se.Render() != "provider/login_failed: ChatGPT plan usage was not granted; sign in again and allow it\n" || se.Exit != 4 {
		t.Fatalf("err = %q", se.Render())
	}
	mustNotExist(t, e.credPath("chatgpt"))
}

func TestChatGPTLoginFailures(t *testing.T) {
	cases := []struct {
		name   string
		setup  func(b *browser, f *fake)
		detail string
		fresh  bool // no earlier login: the sign-in must register Kogen
	}{
		{"denied", func(b *browser, f *fake) { b.redirectError = "access_denied" }, "access_denied: the user denied access", false},
		{"other error", func(b *browser, f *fake) { b.redirectError = "server_error" }, "server_error", false},
		{"no issued client", func(b *browser, f *fake) { b.clientID = "" }, "the sign-in did not register Kogen (no issued client ID)", true},
		{"foreign client", func(b *browser, f *fake) { b.clientID = "dynamic_agent_client" }, "the sign-in did not register Kogen (no issued client ID)", false},
		{"exchange fails", func(b *browser, f *fake) {
			f.authSeq = []handler{jsonAnswer(400, map[string]any{"error": "invalid_grant"})}
		}, "the token exchange failed (400 invalid_grant)", false},
		{"exchange fails no error", func(b *browser, f *fake) { f.authSeq = []handler{jsonAnswer(500, map[string]any{})} }, "the token exchange failed (500 )", false},
		{"nonce mismatch", func(b *browser, f *fake) {
			b.idClaims = func(string) map[string]any { return map[string]any{"nonce": "other"} }
		}, "the sign-in answer does not match this login", false},
		{"no id token", func(b *browser, f *fake) { b.idClaims = func(string) map[string]any { return nil } }, "the sign-in answer does not match this login", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			br := newBrowser(t)
			f := newFake(t).authScript(br.tokens())
			tc.setup(br, f)
			e := newEnv(t, f)
			if !tc.fresh {
				e.saveCreds("chatgpt", e.chatgptCreds())
			}
			before, _ := os.ReadFile(e.credPath("chatgpt"))
			se := mustErr(t, login(e, "chatgpt", br.redirect))
			if se.Class != "provider" || se.Reason != "login_failed" || se.Exit != 4 || se.Detail != tc.detail {
				t.Fatalf("err = %q", se.Render())
			}
			after, _ := os.ReadFile(e.credPath("chatgpt"))
			if string(before) != string(after) {
				t.Fatal("an earlier login was replaced by a failed one")
			}
			if strings.Contains(e.out.String()+e.errs.String()+se.Render(), "AUTH-CODE-SECRET") {
				t.Fatal("code printed")
			}
		})
	}
}

func TestChatGPTLoginTimesOutAfterThreeHundredSeconds(t *testing.T) {
	f := newFake(t)
	e := newEnv(t, f)
	block := make(chan struct{})
	defer close(block)
	// The fake sleep returns at once, which stands for the 300 s passing.
	e.c.Sleep = func(ctx context.Context, d time.Duration) error {
		if d != RedirectWait {
			t.Errorf("waited %v", d)
		}
		return nil
	}
	err := login(e, "chatgpt", func(string) (url.Values, error) { <-block; return nil, nil })
	if se := mustErr(t, err); se.Detail != "no sign-in arrived within 300 seconds" || se.Reason != "login_failed" {
		t.Fatalf("err = %v", err)
	}
}

func TestChatGPTLoginInterrupt(t *testing.T) {
	f := newFake(t)
	e := newEnv(t, f).realClock()
	block := make(chan struct{})
	defer close(block)
	go func() {
		time.Sleep(50 * time.Millisecond)
		e.s.Interrupt("SIGINT")
	}()
	err := login(e, "chatgpt", func(string) (url.Values, error) { <-block; return nil, nil })
	if in, ok := err.(*sys.Interrupted); !ok || in.ExitCode() != 130 {
		t.Fatalf("err = %v (%T)", err, err)
	}
	mustNotExist(t, e.credPath("chatgpt"))
}

func TestChatGPTLoginRedirectErrors(t *testing.T) {
	e := newEnv(t, newFake(t))
	err := login(e, "chatgpt", func(string) (url.Values, error) { return nil, os.ErrClosed })
	if se := mustErr(t, err); se.Reason != "login_failed" || se.Detail != os.ErrClosed.Error() {
		t.Fatalf("err = %v", err)
	}
	err = login(e, "chatgpt", func(string) (url.Values, error) { return nil, sys.Fail("provider", "login_failed", "custom", 4) })
	if mustErr(t, err).Detail != "custom" {
		t.Fatal(err)
	}
}

func TestLoginRefusesNonLoopbackSeamAndUnknownProvider(t *testing.T) {
	e := newEnv(t, nil)
	e.s.Env = append(e.s.Env, "KOGEN_PROVIDER_URL=http://example.com:80")
	se := mustErr(t, login(e, "chatgpt", nil))
	if se.Render() != "environment/invalid_test_seam: KOGEN_PROVIDER_URL must be http://127.0.0.1:<port> or http://localhost:<port>\n" || se.Exit != 3 {
		t.Fatalf("%q", se.Render())
	}
	if err := login(newEnv(t, nil), "grok", nil); err == nil {
		t.Fatal("unknown provider")
	}
}

// ---- SuperGrok ----

func device(mods ...any) handler {
	return jsonAnswer(200, with(map[string]any{
		"device_code": "DEVICE-SECRET", "user_code": "USER", "verification_uri": "https://example.test/verify", "expires_in": int64(20),
	}, mods...))
}

func grant(mods ...any) handler {
	return jsonAnswer(200, with(map[string]any{
		"access_token": "synthetic-access", "refresh_token": "synthetic-refresh",
		"id_token": jwt(map[string]any{"email": "test@example.com"}),
	}, mods...))
}

func oauthError(status int, code string) handler {
	return jsonAnswer(status, map[string]any{"error": code})
}

// supergrok_test: absent scope and interval use RFC defaults; id token never persists.
func TestSuperGrokLoginDefaultsAndStorage(t *testing.T) {
	old := syscall.Umask(0o022)
	defer syscall.Umask(old)
	f := newFake(t).authScript(device(), grant())
	e := newEnv(t, f)
	if err := login(e, "supergrok", nil); err != nil {
		t.Fatal(err)
	}
	if want := "Continue with SuperGrok\nhttps://example.test/verify\nCode: USER\nsupergrok signed in (test@example.com)\n"; e.out.String() != want {
		t.Fatalf("stdout = %q", e.out.String())
	}
	if !reflect.DeepEqual(e.clk.slept(), []time.Duration{5 * time.Second}) {
		t.Fatalf("slept %v (absent interval = 5 s)", e.clk.slept())
	}
	saved := e.readCreds("supergrok")
	want := map[string]any{"client_id": "b1a00492-073a-47ea-816f-4c329264a828", "referrer": "kogen", "access_token": "synthetic-access", "refresh_token": "synthetic-refresh",
		"expires_at": e.clk.Now().Unix() + 3600, "scope": "openid profile email offline_access grok-cli:access api:access", "email": "test@example.com"}
	if !reflect.DeepEqual(saved, want) {
		t.Fatalf("saved = %v", saved)
	}
	auth := f.authRequests()
	if len(auth) != 2 || auth[0].Path != "/oauth2/device/code" || auth[1].Path != "/oauth2/token" {
		t.Fatalf("auth = %+v", auth)
	}
	if !reflect.DeepEqual(map[string][]string(auth[0].Form), map[string][]string{"client_id": {"b1a00492-073a-47ea-816f-4c329264a828"}, "scope": {"openid profile email offline_access grok-cli:access api:access"}, "referrer": {"kogen"}}) {
		t.Fatalf("device form = %v", auth[0].Form)
	}
	if !reflect.DeepEqual(map[string][]string(auth[1].Form), map[string][]string{"grant_type": {"urn:ietf:params:oauth:grant-type:device_code"}, "device_code": {"DEVICE-SECRET"}, "client_id": {"b1a00492-073a-47ea-816f-4c329264a828"}}) {
		t.Fatalf("poll form = %v", auth[1].Form)
	}
	for _, r := range auth {
		if r.Header.Get("Accept") != "application/json" || r.Header.Get("User-Agent") != "kogen/dev+12345678" {
			t.Fatalf("headers = %v", r.Header)
		}
	}
	for _, p := range []string{filepath.Join(e.home, ".kogen"), filepath.Join(e.home, ".kogen", "credentials")} {
		if st, _ := os.Stat(p); st.Mode().Perm() != 0o700 {
			t.Fatalf("%s mode %v", p, st.Mode().Perm())
		}
	}
	if st, _ := os.Stat(e.credPath("supergrok")); st.Mode().Perm() != 0o600 {
		t.Fatal("mode")
	}
	raw, _ := os.ReadFile(e.credPath("supergrok"))
	if strings.Contains(string(raw), "id_token") || strings.Contains(string(raw), "DEVICE-SECRET") || strings.Contains(e.out.String()+e.errs.String(), "DEVICE-SECRET") {
		t.Fatal("id token or device code persisted or printed")
	}
	mustNotExist(t, lockFile(e, "supergrok"))
	if Status(e.home)[1] != "supergrok: signed in (test@example.com)" {
		t.Fatal(Status(e.home))
	}
}

func TestSuperGrokLoginPrefersCompleteURIAndGrantFields(t *testing.T) {
	f := newFake(t).authScript(
		device("verification_uri_complete", "https://example.test/verify?code=USER", "interval", int64(2)),
		grant("scope", "openid api:access", "expires_in", int64(120), "id_token", "garbage"))
	e := newEnv(t, f)
	if err := login(e, "supergrok", nil); err != nil {
		t.Fatal(err)
	}
	if want := "Continue with SuperGrok\nhttps://example.test/verify?code=USER\nCode: USER\nsupergrok signed in\n"; e.out.String() != want {
		t.Fatalf("stdout = %q", e.out.String())
	}
	saved := e.readCreds("supergrok")
	if _, has := saved["email"]; has || saved["scope"] != "openid api:access" || saved["expires_at"] != e.clk.Now().Unix()+120 || !reflect.DeepEqual(e.clk.slept(), []time.Duration{2 * time.Second}) {
		t.Fatalf("saved = %v, slept %v", saved, e.clk.slept())
	}
}

func TestSuperGrokPollPacing(t *testing.T) {
	f := newFake(t).authScript(device("interval", int64(2)), oauthError(400, "authorization_pending"), oauthError(400, "slow_down"), oauthError(400, "authorization_pending"), grant())
	e := newEnv(t, f)
	if err := login(e, "supergrok", nil); err != nil {
		t.Fatal(err)
	}
	// slow_down permanently adds 5 s; pending keeps the interval; the first poll also waits.
	if want := []time.Duration{2 * time.Second, 2 * time.Second, 7 * time.Second, 7 * time.Second}; !reflect.DeepEqual(e.clk.slept(), want) {
		t.Fatalf("slept %v, want %v", e.clk.slept(), want)
	}
	f2 := newFake(t).authScript(device("interval", int64(0)), grant())
	e2 := newEnv(t, f2)
	login(e2, "supergrok", nil)
	if !reflect.DeepEqual(e2.clk.slept(), []time.Duration{time.Second}) {
		t.Fatalf("minimum interval: %v", e2.clk.slept())
	}
}

func TestSuperGrokLoginFailures(t *testing.T) {
	cases := []struct {
		name     string
		script   []handler
		detail   string
		requests int
	}{
		{"device status", []handler{jsonAnswer(500, map[string]any{"error": "temporarily_unavailable"})}, "the SuperGrok device authorization request failed (500 temporarily_unavailable)", 1},
		{"device status no error", []handler{jsonAnswer(403, map[string]any{})}, "the SuperGrok device authorization request failed (403)", 1},
		{"no device code", []handler{device("device_code", "")}, "the SuperGrok device authorization response is incomplete", 1},
		{"no user code", []handler{device("user_code", nil)}, "the SuperGrok device authorization response is incomplete", 1},
		{"no uri", []handler{device("verification_uri", "")}, "the SuperGrok device authorization response is incomplete", 1},
		{"bad lifetime", []handler{device("expires_in", int64(0))}, "the SuperGrok device authorization response is incomplete", 1},
		{"float lifetime", []handler{device("expires_in", 1.5)}, "the SuperGrok device authorization response is incomplete", 1},
		{"http uri", []handler{device("verification_uri", "http://example.test/verify")}, "the SuperGrok verification address is not HTTPS", 1},
		{"hostless uri", []handler{device("verification_uri", "https:///verify")}, "the SuperGrok verification address is not HTTPS", 1},
		{"http complete", []handler{device("verification_uri_complete", "http://example.test/x")}, "the SuperGrok verification address is not HTTPS", 1},
		{"null complete", []handler{device("verification_uri_complete", nil)}, "the SuperGrok verification address is not HTTPS", 1},
		{"denied", []handler{device(), oauthError(400, "access_denied")}, "the SuperGrok sign-in was denied", 2},
		{"authorization denied", []handler{device(), oauthError(400, "authorization_denied")}, "the SuperGrok sign-in was denied", 2},
		{"expired token", []handler{device(), oauthError(400, "expired_token")}, "the SuperGrok sign-in code expired", 2},
		{"other error", []handler{device(), oauthError(400, "server_error")}, "the SuperGrok token request failed (400 server_error)", 2},
		{"other status", []handler{device(), jsonAnswer(502, map[string]any{})}, "the SuperGrok token request failed (502)", 2},
		{"no tokens", []handler{device(), jsonAnswer(200, map[string]any{"access_token": "a"})}, "the SuperGrok sign-in returned no usable tokens", 2},
		{"no api access", []handler{device(), grant("scope", "openid profile")}, "SuperGrok API access was not granted; sign in again and allow it", 2},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newFake(t).authScript(tc.script...)
			e := newEnv(t, f)
			e.saveCreds("supergrok", e.supergrokCreds())
			before, _ := os.ReadFile(e.credPath("supergrok"))
			se := mustErr(t, login(e, "supergrok", nil))
			if se.Class != "provider" || se.Reason != "login_failed" || se.Exit != 4 || se.Detail != tc.detail {
				t.Fatalf("err = %q", se.Render())
			}
			after, _ := os.ReadFile(e.credPath("supergrok"))
			if string(before) != string(after) || len(f.authRequests()) != tc.requests {
				t.Fatalf("credentials changed or %d requests", len(f.authRequests()))
			}
			if strings.Contains(e.out.String(), "DEVICE-SECRET") || strings.Contains(se.Render(), "DEVICE-SECRET") {
				t.Fatal("device code leaked")
			}
		})
	}
}

func TestSuperGrokDeviceRequestNetworkFailure(t *testing.T) {
	f := newFake(t)
	e := newEnv(t, f)
	f.srv.Close()
	if se := mustErr(t, login(e, "supergrok", nil)); se.Detail != "the SuperGrok device authorization request failed (0)" {
		t.Fatalf("%v", se)
	}
}

// supergrok_test: device lifetime expires while a token poll is still in flight.
func TestSuperGrokDeviceLifetimeExpiresWhileAPollIsInFlight(t *testing.T) {
	opened, closed := make(chan struct{}), make(chan struct{})
	hang := func(w http.ResponseWriter, r *http.Request) {
		close(opened)
		<-r.Context().Done()
		close(closed)
	}
	f := newFake(t).authScript(device("expires_in", int64(2), "interval", int64(1)), hang)
	e := newEnv(t, f).realClock()
	e.saveCreds("supergrok", e.supergrokCreds())
	before, _ := os.ReadFile(e.credPath("supergrok"))
	start := time.Now()
	se := mustErr(t, login(e, "supergrok", nil))
	if se.Reason != "login_failed" || se.Detail != "the SuperGrok sign-in code expired" {
		t.Fatalf("err = %v", se)
	}
	select {
	case <-opened:
	default:
		t.Fatal("the poll never started")
	}
	select {
	case <-closed:
	case <-time.After(time.Second):
		t.Fatal("the poll was not cancelled")
	}
	if d := time.Since(start); d < 1900*time.Millisecond || d > 3500*time.Millisecond || len(f.authRequests()) != 2 {
		t.Fatalf("expired after %v with %d requests", d, len(f.authRequests()))
	}
	after, _ := os.ReadFile(e.credPath("supergrok"))
	if string(before) != string(after) {
		t.Fatal("credentials changed")
	}
}

func TestSuperGrokNoPollAtOrAfterTheLifetime(t *testing.T) {
	f := newFake(t).authScript(device("expires_in", int64(2), "interval", int64(1)), oauthError(400, "authorization_pending"), grant())
	e := newEnv(t, f)
	se := mustErr(t, login(e, "supergrok", nil))
	// Poll 1 at t=1; the next wait reaches t=2 = the lifetime, so no second poll starts.
	if se.Detail != "the SuperGrok sign-in code expired" || len(f.authRequests()) != 2 {
		t.Fatalf("%v with %d requests", se, len(f.authRequests()))
	}
}

func TestSuperGrokLoginInterrupt(t *testing.T) {
	f := newFake(t).authScript(device("interval", int64(30)))
	e := newEnv(t, f).realClock()
	go func() {
		time.Sleep(100 * time.Millisecond)
		e.s.Interrupt("SIGHUP")
	}()
	err := login(e, "supergrok", nil)
	if in, ok := err.(*sys.Interrupted); !ok || in.ExitCode() != 129 {
		t.Fatalf("err = %v (%T)", err, err)
	}
	mustNotExist(t, e.credPath("supergrok"))
}

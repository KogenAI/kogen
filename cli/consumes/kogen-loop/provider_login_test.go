package consumes

import (
	"context"
	"net/url"
	"os"
	"strings"
	"syscall"
	"testing"

	"github.com/KogenAI/kogen-loop/provider"
)

// TestCheckSeamsAcceptsOnlyLoopbackTestURLs: kogen's `provider login` and Intent commands refuse
// a KOGEN_PROVIDER_URL or KOGEN_AUTH_URL in the session's environment that is not
// http://127.0.0.1:<port> or http://localhost:<port>: a *sys.Error environment/invalid_test_seam,
// exit 3, naming the variable. Unset variables are fine.
func TestCheckSeamsAcceptsOnlyLoopbackTestURLs(t *testing.T) {
	ok := func(env ...string) {
		t.Helper()
		f := newFixture(t, env...)
		if err := provider.CheckSeams(f.s); err != nil {
			t.Fatalf("CheckSeams(%q) = %v", env, err)
		}
	}
	ok()
	ok("KOGEN_PROVIDER_URL=http://127.0.0.1:8080")
	ok("KOGEN_AUTH_URL=http://localhost:1234", "KOGEN_PROVIDER_URL=http://127.0.0.1:1")
	for _, name := range []string{"KOGEN_PROVIDER_URL", "KOGEN_AUTH_URL"} {
		for _, bad := range []string{"https://127.0.0.1:8080", "http://example.invalid:80", "http://127.0.0.1", "http://127.0.0.1:80/path", ""} {
			f := newFixture(t, name+"="+bad)
			wantFailure(t, provider.CheckSeams(f.s), 3,
				"environment/invalid_test_seam: "+name+" must be http://127.0.0.1:<port> or http://localhost:<port>\n")
		}
	}
}

// TestNewClientKeepsTheVersionAndReadsKeysFromStandardInput: kogen makes one client per command
// with provider.NewClient(version line); its Input is nil, which means the standard input for key
// logins, and kogen replaces it with its own *provider.Input when it has read part of the input.
func TestNewClientKeepsTheVersionAndReadsKeysFromStandardInput(t *testing.T) {
	c := provider.NewClient("kogen dev+12345678 (test)")
	if c == nil || c.Input != nil {
		t.Fatalf("NewClient = %v", c)
	}
	in := keyInput("x")
	c.Input = in
	if c.Input != in {
		t.Fatalf("Input was not kept")
	}
}

// TestStdinInputReadsTheProcessStandardInput: StdinInput is an Input whose Reader is the
// process's standard input; kogen's loginCompatible replaces the Reader with its buffered reader
// over it and sets the result as the client's Input.
func TestStdinInputReadsTheProcessStandardInput(t *testing.T) {
	file, err := os.Create(t.TempDir() + "/stdin")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	original := os.Stdin
	os.Stdin = file
	in := provider.StdinInput()
	os.Stdin = original
	if in.Reader != file {
		t.Fatalf("Reader = %v, want the process's standard input", in.Reader)
	}
	in = stdinInput(t)
	in.Reader = strings.NewReader("fixture-key\n")
	f := newFixture(t)
	c := provider.NewClient("kogen dev+12345678 (test)")
	c.Input = &in
	if err := c.Login(context.Background(), f.s, "opencode-go", nil); err != nil {
		t.Fatal(err)
	}
	if got := f.out(); got != "opencode-go: key saved (not verified)\n" {
		t.Fatalf("output %q", got)
	}
}

// TestLoginSavesAKeyReadFromTheInput: Login of a key provider reads the secret from the client's
// Input.Reader, saves it privately (file 0600 in directories 0700) without any request, prints
// `<name>: key saved (not verified)` (`claude-code: token saved (not verified)` for the Claude Code
// token), and the saved login shows in Status, RequireLogin and ClaudeCodeToken.
func TestLoginSavesAKeyReadFromTheInput(t *testing.T) {
	f := newFixture(t)
	c := provider.NewClient("kogen dev+12345678 (test)")
	for name, line := range map[string]string{
		"opencode-go": "opencode-go: key saved (not verified)\n",
		"anthropic":   "anthropic: key saved (not verified)\n",
		"claude-code": "claude-code: token saved (not verified)\n",
	} {
		before := len(f.out())
		c.Input = keyInput("fixture.key_1-x\n")
		if err := c.Login(f.s.Context(), f.s, name, nil); err != nil {
			t.Fatalf("Login(%s): %v", name, err)
		}
		if got := f.out()[before:]; got != line {
			t.Fatalf("Login(%s) printed %q, want %q", name, got, line)
		}
		path := credentialsFile(f.home, name)
		if m := mode(t, path); m != 0o600 {
			t.Fatalf("%s mode %o", path, m)
		}
		if m := mode(t, f.home+"/.kogen/credentials"); m != 0o700 {
			t.Fatalf("credentials directory mode %o", m)
		}
		if strings.Contains(f.out()+f.stderr.String(), "fixture.key_1-x") {
			t.Fatalf("Login(%s) printed the key", name)
		}
	}
	if tok, ok := provider.ClaudeCodeToken(f.home); !ok || tok != "fixture.key_1-x" {
		t.Fatalf("ClaudeCodeToken = %q, %v", tok, ok)
	}
	if err := provider.RequireLogin(f.home, []provider.Role{{Provider: "opencode-go"}, {Provider: "anthropic"}}); err != nil {
		t.Fatal(err)
	}
	want := []string{"opencode-go: key saved (not verified)", "anthropic: key saved (not verified)", "claude-code: token saved (not verified)"}
	got := provider.Status(f.home)
	if got[2] != want[0] || got[3] != want[1] || got[len(got)-1] != want[2] {
		t.Fatalf("Status = %q", got)
	}
}

// TestLoginRefusalsAreProviderErrorsWithExit4: `kogen provider login` returns the error to
// exitFor, which prints it and exits with its code: a *sys.Error provider/login_failed (provider/login
// for Anthropic) with exit 4 for an unknown provider, an empty key or an invalid Claude Code token,
// leaving the saved login unchanged.
func TestLoginRefusalsAreProviderErrorsWithExit4(t *testing.T) {
	f := newFixture(t)
	c := provider.NewClient("kogen dev+12345678 (test)")
	login := func(name, input string) error {
		c.Input = keyInput(input)
		return c.Login(f.s.Context(), f.s, name, nil)
	}
	wantFailure(t, login("no-such-provider", "x\n"), 4, "provider/login_failed: unknown provider no-such-provider\n")
	wantFailure(t, login("opencode-go", "\n"), 4, "provider/login_failed: no OpenCode Go key supplied; saved login unchanged\n")
	wantFailure(t, login("anthropic", "\n"), 4, "provider/login: no Anthropic key supplied; saved login unchanged\n")
	wantFailure(t, login("claude-code", "two words\n"), 4,
		"provider/login_failed: invalid Claude Code token input: the token must be one line of letters, digits, dot, underscore and hyphen only; saved login unchanged\n")
	if _, err := os.Stat(f.home + "/.kogen/credentials/opencode-go.json"); err == nil {
		t.Fatalf("a refused login saved a file")
	}
}

// TestLoginRefusesAnInvalidSeamBeforeAnythingHappens: Login checks the loopback test seams like
// CheckSeams and returns the same error, so a bad KOGEN_AUTH_URL never reaches the network.
func TestLoginRefusesAnInvalidSeamBeforeAnythingHappens(t *testing.T) {
	f := newFixture(t, "KOGEN_AUTH_URL=https://auth.example.invalid")
	c := provider.NewClient("kogen dev+12345678 (test)")
	err := c.Login(f.s.Context(), f.s, "chatgpt", func(string) (url.Values, error) {
		t.Fatalf("the redirect function was called")
		return nil, nil
	})
	wantFailure(t, err, 3, "environment/invalid_test_seam: KOGEN_AUTH_URL must be http://127.0.0.1:<port> or http://localhost:<port>\n")
}

// TestLoginWithBaseURLBindsAnOpenAICompatibleKeyToItsOrigin: kogen's loginCompatible reads the
// user's base URL, then calls LoginWithBaseURL; the key is saved with that URL's origin
// (shown as saved by Status), an http URL, a missing or an invalid one is refused with exit 4
// without touching the saved login, and Login without a URL refuses openai-compatible.
func TestLoginWithBaseURLBindsAnOpenAICompatibleKeyToItsOrigin(t *testing.T) {
	f := newFixture(t)
	c := provider.NewClient("kogen dev+12345678 (test)")
	with := func(baseURL, key string) error {
		c.Input = keyInput(key)
		return c.LoginWithBaseURL(f.s.Context(), f.s, "openai-compatible", baseURL, nil)
	}
	wantFailure(t, with("http://llm.example.invalid/v1", "k\n"), 4,
		"provider/login_failed: OpenAI-compatible key login needs an HTTPS base URL, not http://llm.example.invalid; saved login unchanged\n")
	wantFailure(t, with("", "k\n"), 4,
		"provider/login_failed: OpenAI-compatible login needs the base URL the key is for; use a login that supplies one (Client.LoginWithBaseURL); saved login unchanged\n")
	wantFailure(t, with("://", "k\n"), 4, "provider/login_failed: invalid OpenAI-compatible base URL; saved login unchanged\n")
	c.Input = keyInput("k\n")
	wantFailure(t, c.Login(f.s.Context(), f.s, "openai-compatible", nil), 4,
		"provider/login_failed: OpenAI-compatible login needs the base URL the key is for; use a login that supplies one (Client.LoginWithBaseURL); saved login unchanged\n")
	if _, err := os.Stat(credentialsFile(f.home, "openai-compatible")); err == nil {
		t.Fatalf("a refused login saved a file")
	}
	if err := with("https://llm.example.invalid:8443/v1/models?x=1", "fixture-key\r\n"); err != nil {
		t.Fatal(err)
	}
	if got := f.out(); got != "openai-compatible: key saved (not verified)\n" {
		t.Fatalf("output %q", got)
	}
	saved := readFile(t, credentialsFile(f.home, "openai-compatible"))
	if !strings.Contains(saved, `"api_key": "fixture-key"`) && !strings.Contains(saved, `"api_key":"fixture-key"`) {
		t.Fatalf("saved login %s", saved)
	}
	if !strings.Contains(saved, "https://llm.example.invalid:8443") || strings.Contains(saved, "/v1") {
		t.Fatalf("saved login %s is not bound to the origin only", saved)
	}
	if got := provider.Status(f.home); got[len(got)-1] != "openai-compatible: key saved (not verified)" {
		t.Fatalf("Status = %q", got)
	}
}

// TestLoginSignsInToChatGPTThroughTheRedirectFunc: Login of chatgpt prints `Continue with ChatGPT`
// and the authorization address (under KOGEN_AUTH_URL), hands that address to the RedirectFunc,
// ignores a redirect whose state is not this sign-in's (noting it on standard error), exchanges
// the code at the token endpoint with the PKCE verifier, and saves the login privately: it prints
// `chatgpt signed in (<email>)` and Status and RequireLogin see it.
func TestLoginSignsInToChatGPTThroughTheRedirectFunc(t *testing.T) {
	auth := newAuthServer(t)
	f := newFixture(t, "KOGEN_AUTH_URL="+auth.URL)
	var seen []string
	redirect := auth.redirect(t, &seen, url.Values{"state": {"someone-else"}, "code": {"x"}}, url.Values{"client_id": {"oaiapp_fixture"}})
	c := provider.NewClient("kogen dev+12345678 (test)")
	if err := c.Login(f.s.Context(), f.s, "chatgpt", redirect); err != nil {
		t.Fatal(err)
	}
	if len(seen) != 2 || !strings.HasPrefix(seen[0], auth.URL+"/api/accounts/authorize?") {
		t.Fatalf("redirect function saw %q", seen)
	}
	want := "Continue with ChatGPT\n" + seen[0] + "\nchatgpt signed in (user@example.invalid)\n"
	if got := f.out(); got != want {
		t.Fatalf("output %q, want %q", got, want)
	}
	if got := f.stderr.String(); got != "kogen: ignored a sign-in redirect with the wrong state\n" {
		t.Fatalf("standard error %q", got)
	}
	form := auth.lastForm(t)
	u, _ := url.Parse(seen[0])
	if form.Get("grant_type") != "authorization_code" || form.Get("code") != "code-1" || form.Get("client_id") != "oaiapp_fixture" ||
		challengeOf(form.Get("code_verifier")) != u.Query().Get("code_challenge") || u.Query().Get("code_challenge_method") != "S256" {
		t.Fatalf("token request %v for %s", form, seen[0])
	}
	if m := mode(t, credentialsFile(f.home, "chatgpt")); m != 0o600 {
		t.Fatalf("login file mode %o", m)
	}
	if got := provider.Status(f.home)[0]; got != "chatgpt: signed in (user@example.invalid)" {
		t.Fatalf("Status = %q", got)
	}
	if err := provider.RequireLogin(f.home, []provider.Role{{}}); err != nil {
		t.Fatal(err)
	}
}

// TestLoginToChatGPTFailsWithProviderErrors: a redirect that carries an error, and a token
// endpoint that refuses, are *sys.Error provider/login_failed with exit 4, and nothing is saved.
func TestLoginToChatGPTFailsWithProviderErrors(t *testing.T) {
	auth := newAuthServer(t)
	f := newFixture(t, "KOGEN_AUTH_URL="+auth.URL)
	c := provider.NewClient("kogen dev+12345678 (test)")
	var seen []string
	denied := auth.redirect(t, &seen, nil, url.Values{"error": {"access_denied"}, "error_description": {"no"}})
	wantFailure(t, c.Login(f.s.Context(), f.s, "chatgpt", denied), 4, "provider/login_failed: access_denied: no\n")
	auth.mu.Lock()
	auth.status = 400
	auth.mu.Unlock()
	refused := auth.redirect(t, &seen, nil, url.Values{"client_id": {"oaiapp_fixture"}})
	wantFailure(t, c.Login(f.s.Context(), f.s, "chatgpt", refused), 4, "provider/login_failed: the token exchange failed (400 invalid_grant)\n")
	if _, err := os.Stat(credentialsFile(f.home, "chatgpt")); err == nil {
		t.Fatalf("a failed sign-in saved a login")
	}
}

// TestLoginToChatGPTStopsOnAnInterrupt: when the caller interrupts while the sign-in waits for the
// redirect, Login returns the session's *sys.Interrupted, which kogen's exitFor turns into 130,
// 143 or 129.
func TestLoginToChatGPTStopsOnAnInterrupt(t *testing.T) {
	auth := newAuthServer(t)
	f := newFixture(t, "KOGEN_AUTH_URL="+auth.URL)
	c := provider.NewClient("kogen dev+12345678 (test)")
	waiting, release := make(chan struct{}), make(chan struct{})
	done := make(chan error, 1)
	go func() {
		done <- c.Login(f.s.Context(), f.s, "chatgpt", func(string) (url.Values, error) {
			close(waiting)
			<-release
			return nil, nil
		})
	}()
	<-waiting
	interrupt(t, f.s, syscall.SIGTERM)
	err := <-done
	close(release)
	if !isInterrupted(err, 143) {
		t.Fatalf("Login returned %v (%T), want *sys.Interrupted with exit 143", err, err)
	}
	if _, err := os.Stat(credentialsFile(f.home, "chatgpt")); err == nil {
		t.Fatalf("an interrupted sign-in saved a login")
	}
}

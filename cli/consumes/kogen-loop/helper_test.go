package consumes

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/KogenAI/kogen-loop/provider"
	"github.com/KogenAI/kogen-loop/sys"
)

// fixture is one synthetic world: a HOME of its own under t.TempDir() and the session kogen
// would make with sys.New(), whose standard output goes to a file the test reads back.
type fixture struct {
	t      *testing.T
	home   string
	dir    string
	stdout *os.File
	stderr *strings.Builder
	s      *sys.Session
}

// newFixture makes a session with sys.New (which takes the process's standard output at that
// moment, here a file of the fixture's own) whose environment is the process's with HOME
// replaced and extra variables added, as kogen's callers see it.
func newFixture(t *testing.T, extra ...string) *fixture {
	t.Helper()
	base, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	f := &fixture{t: t, home: filepath.Join(base, "home"), dir: filepath.Join(base, "work"), stderr: &strings.Builder{}}
	for _, d := range []string{f.home, f.dir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	f.stdout, err = os.Create(filepath.Join(base, "stdout"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { f.stdout.Close() })
	original := os.Stdout
	os.Stdout = f.stdout
	f.s = sys.New()
	os.Stdout = original
	f.s.Stderr = f.stderr
	f.s.Env = append(append(os.Environ(), "HOME="+f.home), extra...)
	return f
}

// out is everything the session wrote to its standard output so far.
func (f *fixture) out() string {
	f.t.Helper()
	b, err := os.ReadFile(f.stdout.Name())
	if err != nil {
		f.t.Fatal(err)
	}
	return string(b)
}

// stdinInput is provider.StdinInput taken while the process's standard input is a regular file,
// so that the result does not depend on how the test binary was started.
func stdinInput(t *testing.T) provider.Input {
	t.Helper()
	file, err := os.Create(filepath.Join(t.TempDir(), "stdin"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { file.Close() })
	original := os.Stdin
	os.Stdin = file
	defer func() { os.Stdin = original }()
	return provider.StdinInput()
}

// keyInput is the input a key login reads its secret from.
func keyInput(text string) *provider.Input {
	return &provider.Input{Reader: strings.NewReader(text)}
}

// wantFailure checks that err is a *sys.Error with the exit code and the rendering.
func wantFailure(t *testing.T, err error, exit int, render string) {
	t.Helper()
	e, ok := sys.AsError(err)
	if !ok {
		t.Fatalf("error %v (%T), want *sys.Error %q", err, err, render)
	}
	if e.Exit != exit || e.Render() != render {
		t.Fatalf("error exit %d, rendering %q; want exit %d, %q", e.Exit, e.Render(), exit, render)
	}
}

// writeFile writes a private file of the fixture, making its directories.
func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

// credentialsFile is where kogen's sign-ins keep one provider's login under home.
func credentialsFile(home, name string) string {
	return filepath.Join(home, ".kogen", "credentials", name+".json")
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func mode(t *testing.T, path string) os.FileMode {
	t.Helper()
	st, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	return st.Mode().Perm()
}

// authServer is a loopback ChatGPT authorization server on a free port. It answers the token
// request of a sign-in with the tokens its test configured and records the request's form.
type authServer struct {
	*httptest.Server
	mu     sync.Mutex
	nonce  string
	status int
	forms  []url.Values
}

func newAuthServer(t *testing.T) *authServer {
	t.Helper()
	a := &authServer{status: 200}
	a.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.ParseForm()
		a.mu.Lock()
		defer a.mu.Unlock()
		a.forms = append(a.forms, r.PostForm)
		if r.URL.Path != "/api/accounts/oauth/token" {
			w.WriteHeader(404)
			return
		}
		w.WriteHeader(a.status)
		if a.status != 200 {
			fmt.Fprint(w, `{"error":"invalid_grant"}`)
			return
		}
		claims, _ := json.Marshal(map[string]any{"nonce": a.nonce, "email": "user@example.invalid"})
		idToken := "e30." + base64.RawURLEncoding.EncodeToString(claims) + ".sig"
		json.NewEncoder(w).Encode(map[string]any{
			"access_token": "fake-access", "refresh_token": "fake-refresh", "expires_in": 3600,
			"scope": "openid chatgpt.tokens.use.direct", "id_token": idToken,
		})
	}))
	t.Cleanup(a.Close)
	return a
}

// redirect is the RedirectFunc of a caller that opens the authorization address and gets the
// answer: it reads the state, the nonce and the challenge from the address, tells the server
// the nonce for the id token, and returns the query of the redirect with the given extras.
// wrong, when set, is returned first with a state that is not this sign-in's.
func (a *authServer) redirect(t *testing.T, seen *[]string, wrong url.Values, extra url.Values) provider.RedirectFunc {
	var once sync.Once
	return func(authURL string) (url.Values, error) {
		*seen = append(*seen, authURL)
		u, err := url.Parse(authURL)
		if err != nil {
			return nil, err
		}
		q := u.Query()
		a.mu.Lock()
		a.nonce = q.Get("nonce")
		a.mu.Unlock()
		first := false
		once.Do(func() { first = true })
		if first && wrong != nil {
			return wrong, nil
		}
		answer := url.Values{"state": {q.Get("state")}, "code": {"code-1"}}
		for k, v := range extra {
			answer[k] = v
		}
		return answer, nil
	}
}

func (a *authServer) lastForm(t *testing.T) url.Values {
	t.Helper()
	a.mu.Lock()
	defer a.mu.Unlock()
	if len(a.forms) == 0 {
		t.Fatal("the authorization server received no token request")
	}
	return a.forms[len(a.forms)-1]
}

// challengeOf is the S256 code challenge of a verifier.
func challengeOf(verifier string) string {
	sum := sha256.Sum256([]byte(verifier))
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

func isInterrupted(err error, code int) bool {
	var in *sys.Interrupted
	return errors.As(err, &in) && in.ExitCode() == code
}

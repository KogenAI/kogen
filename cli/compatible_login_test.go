package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen/agent"
)

// K-CRED-ORIGIN: `kogen provider login openai-compatible` reads the base URL the key is for,
// then the key, and the loop binds the key to that URL's origin. Every world is a fixture
// home, a temporary repository and a local transport; no real credential or network is used.

const (
	originKeyFixture = "KEY"
	conflictingRepo  = "https://b.example/v1"
)

// compatibleWorld is a fixture HOME and a repository whose project.yaml names a different
// base URL than the one a user logs in with.
func compatibleWorld(t *testing.T) (home string) {
	t.Helper()
	home = t.TempDir()
	t.Setenv("HOME", home)
	repo := t.TempDir()
	if err := os.MkdirAll(filepath.Join(repo, ".kogen"), 0o755); err != nil {
		t.Fatal(err)
	}
	yaml := "models:\n  build: {provider: openai-compatible, model: m, effort: default, base_url: '" + conflictingRepo + "'}\n"
	if err := os.WriteFile(filepath.Join(repo, ".kogen", "project.yaml"), []byte(yaml), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Chdir(repo)
	return home
}

// loginCLI runs `kogen provider login openai-compatible` in this process with input as the
// whole of its piped standard input and returns the exit code and stdout.
func loginCLI(t *testing.T, input string) (int, string) {
	t.Helper()
	inR, inW, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	outR, outW, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	stdin, stdout := os.Stdin, os.Stdout
	os.Stdin, os.Stdout = inR, outW
	defer func() { os.Stdin, os.Stdout = stdin, stdout }()
	io.WriteString(inW, input)
	inW.Close()
	root := t.TempDir()
	code := run([]string{"provider", "login", "openai-compatible"}, func() (string, error) { return root, nil })
	outW.Close()
	out, _ := io.ReadAll(outR)
	inR.Close()
	outR.Close()
	return code, string(out)
}

func savedCompatible(t *testing.T, home string) map[string]any {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(home, ".kogen", "credentials", "openai-compatible.json"))
	if err != nil {
		t.Fatal(err)
	}
	var c map[string]any
	if err := json.Unmarshal(b, &c); err != nil {
		t.Fatal(err)
	}
	return c
}

// recordingTransport answers every request with a Chat Completions success and keeps what it saw.
type recordingTransport struct {
	mu   sync.Mutex
	reqs []*http.Request
}

func (r *recordingTransport) RoundTrip(q *http.Request) (*http.Response, error) {
	r.mu.Lock()
	r.reqs = append(r.reqs, q)
	r.mu.Unlock()
	body := `{"id":"chatcmpl-fixture","model":"m","choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}`
	return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": {"application/json"}}, Body: io.NopCloser(strings.NewReader(body)), Request: q}, nil
}

func (r *recordingTransport) requests() []*http.Request {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]*http.Request(nil), r.reqs...)
}

// respondAt makes one request on the provider path for a role at baseURL, with only rt as transport.
func respondAt(t *testing.T, home string, rt http.RoundTripper, baseURL string) error {
	t.Helper()
	s := sys.NewWith([]string{"HOME=" + home, "PATH=" + os.Getenv("PATH")}, home)
	client := provider.NewClient("kogen dev+12345678 (test)")
	client.HTTP = &http.Client{Transport: rt}
	role := provider.Role{Provider: "openai-compatible", Model: "m", Effort: "default", BaseURL: baseURL}
	input := []any{map[string]any{"role": "user", "content": []any{map[string]any{"type": "input_text", "text": "hi"}}}}
	_, err := client.Respond(context.Background(), s, provider.Request{Role: role, Instructions: "policy", Input: input, Scope: "s"}, nil)
	return err
}

func TestCompatibleLoginUserOrigin(t *testing.T) {
	home := compatibleWorld(t)
	code, out := loginCLI(t, "https://a.example/v1\nKEY\n")
	if want := "Base URL:\nAPI key:\nopenai-compatible: key saved (not verified)\n"; code != 0 || out != want {
		t.Fatalf("login = %d %q, want 0 %q", code, out, want)
	}
	c := savedCompatible(t, home)
	if len(c) != 3 || c["provider"] != "openai-compatible" || c["api_key"] != originKeyFixture || c["origin"] != "https://a.example" {
		t.Fatalf("saved credential %v: the repository's %s must have no influence", c, conflictingRepo)
	}
	if strings.Contains(out, originKeyFixture) {
		t.Fatalf("the key was printed: %q", out)
	}

	// A URL the loop refuses keeps the saved login byte for byte, whatever the key line says.
	path := filepath.Join(home, ".kogen", "credentials", "openai-compatible.json")
	before, _ := os.ReadFile(path)
	for _, input := range []string{"http://a.example/v1\nOTHER\n", "\nOTHER\n", "not a url\nOTHER\n"} {
		code, out := loginCLI(t, input)
		if code != 4 || !strings.Contains(out, "provider/login_failed: ") || strings.Contains(out, "OTHER") {
			t.Fatalf("%q = %d %q", input, code, out)
		}
		if after, _ := os.ReadFile(path); !bytes.Equal(after, before) {
			t.Fatalf("%q changed the saved login", input)
		}
	}
}

func TestCompatibleLoginRoleOrigins(t *testing.T) {
	home := compatibleWorld(t)
	if code, out := loginCLI(t, "https://a.example/v1\nKEY\n"); code != 0 {
		t.Fatalf("login = %d %q", code, out)
	}

	matching := &recordingTransport{}
	if err := respondAt(t, home, matching, "https://a.example/v1"); err != nil {
		t.Fatalf("a role at the login's origin failed: %v", err)
	}
	reqs := matching.requests()
	if len(reqs) != 1 || reqs[0].URL.String() != "https://a.example/v1/chat/completions" || reqs[0].Header.Get("Authorization") != "Bearer KEY" {
		t.Fatalf("matching origin sent %d requests, first %v", len(reqs), reqs)
	}

	other := &recordingTransport{}
	err := respondAt(t, home, other, conflictingRepo)
	if err == nil {
		t.Fatal("a role at another origin was served")
	}
	if n := len(other.requests()); n != 0 {
		t.Fatalf("%d requests were sent to a different origin", n)
	}
	e, ok := sys.AsError(err)
	if !ok || e.Class != "provider" || e.Reason != "refused" || !strings.Contains(e.Detail, "belongs to https://a.example but this request goes to https://b.example") {
		t.Fatalf("origin error = %v", err)
	}
	if strings.Contains(e.Render(), originKeyFixture) {
		t.Fatalf("the key is in %q", e.Render())
	}
	// Where Shape and Build print it, the refusal names the re-login command.
	if shown := agent.WithOriginHint(e).Render(); !strings.Contains(shown, "kogen provider login openai-compatible") || !strings.Contains(shown, "belongs to https://a.example") {
		t.Fatalf("shown error %q", shown)
	}
}

func TestCompatibleLoginLegacyOriginHint(t *testing.T) {
	home := compatibleWorld(t)
	dir := filepath.Join(home, ".kogen", "credentials")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "openai-compatible.json"), []byte(`{"provider":"openai-compatible","api_key":"KEY"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	rt := &recordingTransport{}
	err := respondAt(t, home, rt, "https://a.example/v1")
	if err == nil {
		t.Fatal("a key without an origin was used")
	}
	if n := len(rt.requests()); n != 0 {
		t.Fatalf("%d requests were sent with a legacy key", n)
	}
	e, ok := sys.AsError(err)
	if !ok || e.Class != "provider" || e.Reason != "login" || !strings.Contains(e.Detail, "not bound to an origin") {
		t.Fatalf("legacy error = %v", err)
	}
	if shown := agent.WithOriginHint(e).Render(); !strings.Contains(shown, "kogen provider login openai-compatible") || strings.Contains(shown, "KEY") {
		t.Fatalf("shown error %q", shown)
	}
}

func TestCompatibleLoginContractText(t *testing.T) {
	code, help := runCaptured(t, "provider", "login", "-h")
	if code != 0 || !strings.Contains(help, "  login openai-compatible  Save a key for an OpenAI-compatible host: its base URL line, then the key line (stdin or terminal)\n") {
		t.Fatalf("help = %d %q", code, help)
	}
	// No new command, subcommand or flag: the same commands, and a URL flag is a usage error.
	if n := strings.Count(help, "\n  login "); n != 6 {
		t.Fatalf("%d login lines in %q", n, help)
	}
	for _, args := range [][]string{
		{"provider", "login", "openai-compatible", "--base-url", "https://a.example/v1"},
		{"provider", "login", "openai-compatible", "https://a.example/v1"},
	} {
		if code, out := runCaptured(t, args...); code != 2 {
			t.Fatalf("kogen %v = %d %q, want a usage error", args, code, out)
		}
	}

	read := func(path string) string {
		b, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	contract := []string{
		"`Base URL:`", "`API key:`", "`.kogen/project.yaml`", "HTTPS", "origin",
		"kogen provider login openai-compatible",
	}
	for _, doc := range []string{"../docs/configuration.md", "../spec/prose/08-chatgpt.md"} {
		text := read(doc)
		start := strings.Index(text, "kogen provider login openai-compatible")
		if start < 0 {
			t.Fatalf("%s does not document the compatible login", doc)
		}
		for _, want := range contract {
			if !strings.Contains(text, want) {
				t.Errorf("%s lacks %s", doc, want)
			}
		}
		for _, stale := range []string{"reads one from\n  stdin (not echoed", "reads it from stdin (not echoed"} {
			if strings.Contains(text, stale) {
				t.Errorf("%s still documents the key-only stdin login: %q", doc, stale)
			}
		}
	}
	if !strings.Contains(read("../spec/prose/09-cli-and-process.md"), "login openai-compatible  Save a key for an OpenAI-compatible host: its base URL line, then the key line (stdin or terminal)") {
		t.Error("spec chapter 09 lacks the changed help line")
	}
	if !strings.Contains(read("../spec/features/08-chatgpt.feature"), "Base URL:") {
		t.Error("the spec's CLI scenarios do not cover the two-line login")
	}
	if !strings.Contains(read("../README.md"), "reads the key's base URL line, then the key line") {
		t.Error("README does not document the two-line login")
	}
}

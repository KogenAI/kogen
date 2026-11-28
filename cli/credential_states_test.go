package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/KogenAI/kogen-coordinator/project"
)

const stateKey = "sk-fake-state-key-0123456789"

// stateHome writes a saved key bound to origin the way the login stores it.
func stateHome(t *testing.T, origin string) string {
	t.Helper()
	home := t.TempDir()
	dir := filepath.Join(home, ".kogen", "credentials")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	body := `{"provider":"openai-compatible","api_key":"` + stateKey + `","origin":"` + origin + `"}`
	if err := os.WriteFile(filepath.Join(dir, "openai-compatible.json"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return home
}

func serve(t *testing.T, h http.HandlerFunc) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(h)
	t.Cleanup(srv.Close)
	return srv
}

func TestConnectionTestClassifiesTheAnswer(t *testing.T) {
	sse := "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n"
	plain := `{"id":"x","choices":[{"message":{"content":"ok"}}]}`
	cases := []struct {
		name   string
		status int
		body   string
		ok     bool
		class  string
	}{
		{"stream", 200, sse, true, ""},
		{"plain json", 200, plain, true, ""},
		{"401", 401, "echo " + stateKey, false, classAuth},
		{"403", 403, "echo " + stateKey, false, classAuth},
		{"404", 404, "", false, classEndpoint},
		{"500", 500, "", false, classEndpoint},
		{"redirect", 302, "", false, classEndpoint},
		{"html", 200, "<html>hello</html>", false, classMalformed},
		{"json without choices", 200, `{"ok":true}`, false, classMalformed},
		{"choices not an array", 200, `{"choices":{}}`, false, classMalformed},
		{"stream without choices", 200, "data: {\"x\":1}\n\ndata: [DONE]\n\n", false, classMalformed},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			srv := serve(t, func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Location", "http://127.0.0.1:1/elsewhere")
				w.WriteHeader(c.status)
				w.Write([]byte(c.body))
			})
			home := stateHome(t, srv.URL)
			res, err := testConnection(context.Background(), home, project.Role{Provider: testableProvider, Model: "m", BaseURL: srv.URL + "/v1"})
			if err != nil {
				t.Fatal(err)
			}
			if res.OK != c.ok || res.Class != c.class {
				t.Fatalf("got ok=%v class=%q detail=%q", res.OK, res.Class, res.Detail)
			}
			if line := res.line(testableProvider); strings.Contains(line, stateKey) || strings.Contains(line, "echo") || strings.Contains(line, "hello") {
				t.Fatalf("the line leaks the reply: %s", line)
			}
			rec, ok := readConnectionRecord(home, testableProvider)
			if !ok || (rec.Result == "ok") != c.ok || rec.Class != c.class || rec.Origin != srv.URL {
				t.Fatalf("record %+v ok=%v", rec, ok)
			}
		})
	}
}

func TestConnectionTestSendsOneMinimalStreamingRequest(t *testing.T) {
	var got []string
	srv := serve(t, func(w http.ResponseWriter, r *http.Request) {
		buf := new(strings.Builder)
		b := make([]byte, 4096)
		n, _ := r.Body.Read(b)
		buf.Write(b[:n])
		got = append(got, r.Method+" "+r.URL.Path+" "+r.Header.Get("Authorization")+" "+buf.String())
		w.Write([]byte(`{"choices":[]}`))
	})
	home := stateHome(t, srv.URL)
	if _, err := testConnection(context.Background(), home, project.Role{Provider: testableProvider, Model: "m", BaseURL: srv.URL + "/v1/"}); err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || !strings.HasPrefix(got[0], "POST /v1/chat/completions Bearer "+stateKey+" ") {
		t.Fatalf("requests: %v", got)
	}
	for _, want := range []string{`"stream":true`, `"max_tokens":8`, `"role":"user"`} {
		if !strings.Contains(got[0], want) {
			t.Fatalf("request lacks %s: %s", want, got[0])
		}
	}
	if strings.Contains(got[0], "tools") {
		t.Fatalf("request carries tools: %s", got[0])
	}
}

func TestConnectionTestNoConnectionIsEndpoint(t *testing.T) {
	srv := httptest.NewServer(http.NotFoundHandler())
	url := srv.URL
	srv.Close()
	res, err := testConnection(context.Background(), stateHome(t, url), project.Role{Provider: testableProvider, Model: "m", BaseURL: url + "/v1"})
	if err != nil || res.OK || res.Class != classEndpoint {
		t.Fatalf("res %+v err %v", res, err)
	}
}

func TestConnectionTestWatchdogIsTimeout(t *testing.T) {
	old := connectionWatchdog
	connectionWatchdog = 200 * time.Millisecond
	t.Cleanup(func() { connectionWatchdog = old })
	done := make(chan struct{})
	srv := serve(t, func(w http.ResponseWriter, r *http.Request) { <-done })
	t.Cleanup(func() { close(done) })
	res, err := testConnection(context.Background(), stateHome(t, srv.URL), project.Role{Provider: testableProvider, Model: "m", BaseURL: srv.URL + "/v1"})
	if err != nil || res.OK || res.Class != classTimeout {
		t.Fatalf("res %+v err %v", res, err)
	}
}

func TestConnectionTestRefusesWithoutSendingOrRecording(t *testing.T) {
	hits := 0
	srv := serve(t, func(w http.ResponseWriter, r *http.Request) { hits++ })
	cases := []struct{ name, saved, base string }{
		{"another origin", "https://example.com", srv.URL + "/v1"},
		{"no saved origin", "", srv.URL + "/v1"},
		{"plain http off loopback", "http://example.com", "http://example.com/v1"},
	}
	for _, c := range cases {
		home := stateHome(t, c.saved)
		_, err := testConnection(context.Background(), home, project.Role{Provider: testableProvider, Model: "m", BaseURL: c.base})
		if err == nil {
			t.Fatalf("%s: no refusal", c.name)
		}
		if strings.Contains(err.Error(), stateKey) {
			t.Fatalf("%s: the refusal names the key: %v", c.name, err)
		}
		if _, ok := readConnectionRecord(home, testableProvider); ok {
			t.Fatalf("%s: a refusal recorded a result", c.name)
		}
	}
	if hits != 0 {
		t.Fatalf("%d requests were sent", hits)
	}
}

func TestFailedTestReplacesEarlierSuccess(t *testing.T) {
	status := 200
	srv := serve(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(status)
		w.Write([]byte(`{"choices":[]}`))
	})
	home := stateHome(t, srv.URL)
	role := project.Role{Provider: testableProvider, Model: "m", BaseURL: srv.URL + "/v1"}
	if res, err := testConnection(context.Background(), home, role); err != nil || !res.OK {
		t.Fatalf("%+v %v", res, err)
	}
	if _, ok := connectionHeld(home, testableProvider, srv.URL); !ok {
		t.Fatal("connection tested does not hold after a success")
	}
	status = 401
	if _, err := testConnection(context.Background(), home, role); err != nil {
		t.Fatal(err)
	}
	if c, ok := connectionHeld(home, testableProvider, ""); ok {
		t.Fatalf("connection tested still holds: %s", c)
	}
	st, err := os.Stat(connectionRecordPath(home, testableProvider))
	if err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("record mode: %v %v", st, err)
	}
}

func TestRoleHoldsConnectionTestedOnlyForTheRecordedOrigin(t *testing.T) {
	srv := serve(t, func(w http.ResponseWriter, r *http.Request) { w.Write([]byte(`{"choices":[]}`)) })
	home := stateHome(t, srv.URL)
	role := project.Role{Provider: testableProvider, Model: "m", BaseURL: srv.URL + "/v1"}
	if _, err := testConnection(context.Background(), home, role); err != nil {
		t.Fatal(err)
	}
	same := roleStatesLine(home, "", "build", role, true)
	if !strings.HasPrefix(same, "states role build (openai-compatible, m): key saved; connection tested 20") {
		t.Fatal(same)
	}
	other := role
	other.BaseURL = "https://example.com/v1"
	if got := roleStatesLine(home, "", "build", other, true); got != "states role build (openai-compatible, m): key saved" {
		t.Fatal(got)
	}
	if got := roleStatesLine(home, "", "review", project.Role{Provider: "chatgpt", Model: "g"}, false); got != "states role review (chatgpt, g): none" {
		t.Fatal(got)
	}
}

func TestRoleVerifiedReadsOnlyTheQualificationTable(t *testing.T) {
	docs := "# Providers\n\n| Provider | Account | Roles verified | Built | Setup |\n| --- | --- | --- | --- | --- |\n" +
		"| `chatgpt` | x | Shape: verified (`spec/a.md`); Build: not qualified; Review: verified (`spec/a.md`) | Built in | s |\n" +
		"| `openai-compatible` | x | Shape: not qualified; Build: not qualified; Review: not qualified | Custom | s |\n\n" +
		"experimental: Build verified with Claude Review\n"
	for _, c := range []struct {
		provider, role string
		want           bool
	}{
		{"chatgpt", "shape", true}, {"chatgpt", "build", false}, {"chatgpt", "review", true},
		{"openai-compatible", "build", false}, {"anthropic", "build", false},
	} {
		if got := roleVerifiedIn(docs, c.provider, c.role); got != c.want {
			t.Errorf("%s %s: got %v", c.provider, c.role, got)
		}
	}
	if roleVerifiedIn("", "chatgpt", "shape") {
		t.Error("a missing file verifies a role")
	}
	// The shipped table: chatgpt Build is verified, QwenCloud's build role is not.
	shipped, err := os.ReadFile("../docs/providers.md")
	if err != nil {
		t.Fatal(err)
	}
	if !roleVerifiedIn(string(shipped), "chatgpt", "build") || roleVerifiedIn(string(shipped), "openai-compatible", "build") {
		t.Error("the shipped table is read wrongly")
	}
	if shippedDocs(t.TempDir()) != "" {
		t.Error("docs found in an empty install root")
	}
}

func TestProviderStatesLines(t *testing.T) {
	home := t.TempDir()
	lines := providerStates(home, []string{
		"chatgpt: signed in (a@b.c)",
		"anthropic: not signed in",
		"opencode-go: key saved (not verified)",
		"claude-code: token saved (not verified)",
		"supergrok: saved login cannot be used; run kogen provider login supergrok",
	})
	want := []string{
		"states chatgpt: key saved",
		"states anthropic: none",
		"states opencode-go: key saved",
		"states claude-code: key saved",
		"states supergrok: none",
	}
	if strings.Join(lines, "\n") != strings.Join(want, "\n") {
		t.Fatalf("got\n%s", strings.Join(lines, "\n"))
	}
	if !keySavedStatus("managed access snapshot fresh (local status only)") || keySavedStatus("saved key has no origin; log in again") {
		t.Fatal("key saved status wrongly derived")
	}
}

func TestLabelsMatchTheDocsSection(t *testing.T) {
	shipped, err := os.ReadFile("../docs/providers.md")
	if err != nil {
		t.Fatal(err)
	}
	for _, l := range []string{labelKeySaved, labelConnectionTried, labelRoleVerified} {
		if !strings.Contains(string(shipped), "- `"+l+"` means ") {
			t.Errorf("docs/providers.md does not define %q", l)
		}
	}
}

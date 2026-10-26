package provider

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"testing"
)

func TestStatusLines(t *testing.T) {
	e := newEnv(t, nil)
	check := func(want ...string) {
		t.Helper()
		if got := Status(e.home); !reflect.DeepEqual(got, want) {
			t.Fatalf("Status = %q, want %q", got, want)
		}
	}
	check("chatgpt: not signed in", "supergrok: not signed in", "opencode-go: not signed in", "anthropic: not signed in")
	e.saveCreds("chatgpt", e.chatgptCreds("email", "user@example.com"))
	check("chatgpt: signed in (user@example.com)", "supergrok: not signed in", "opencode-go: not signed in", "anthropic: not signed in")
	e.saveCreds("chatgpt", e.chatgptCreds())
	check("chatgpt: signed in", "supergrok: not signed in", "opencode-go: not signed in", "anthropic: not signed in")
	// GPT-4: an incomplete saved login is not reported as signed in.
	e.saveCreds("chatgpt", map[string]any{"client_id": "oaiapp_test", "refresh_token": "refresh-token", "email": "user@example.com"})
	check("chatgpt: saved login cannot be used; run kogen provider login chatgpt", "supergrok: not signed in", "opencode-go: not signed in", "anthropic: not signed in")
	for name, creds := range map[string]map[string]any{
		"short client id": e.chatgptCreds("client_id", "oaiapp_"),
		"foreign client":  e.chatgptCreds("client_id", "dynamic_agent_client"),
		"float expiry":    e.chatgptCreds("expires_at", 1.7e9),
		"empty access":    e.chatgptCreds("access_token", ""),
	} {
		e.saveCreds("chatgpt", creds)
		if got := Status(e.home)[0]; got != "chatgpt: saved login cannot be used; run kogen provider login chatgpt" {
			t.Errorf("%s: %s", name, got)
		}
	}
	os.WriteFile(e.credPath("chatgpt"), []byte("not json"), 0o600)
	check("chatgpt: saved login cannot be used; run kogen provider login chatgpt", "supergrok: not signed in", "opencode-go: not signed in", "anthropic: not signed in")
	os.Remove(e.credPath("chatgpt"))
	e.saveCreds("supergrok", e.supergrokCreds("email", "grok@example.com", "expires_at", int64(0)))
	check("chatgpt: not signed in", "supergrok: signed in (grok@example.com)", "opencode-go: not signed in", "anthropic: not signed in")
	e.saveCreds("supergrok", e.supergrokCreds("referrer", "another-harness"))
	check("chatgpt: not signed in", "supergrok: saved login cannot be used; run kogen provider login supergrok", "opencode-go: not signed in", "anthropic: not signed in")
}

// supergrok_test: selected roles check only their own providers; a saved borrowed login is
// refused offline.
func TestRequireLoginChecksOnlyUsedProviders(t *testing.T) {
	f := newFake(t)
	e := newEnv(t, f)
	grok := []Role{grokRole}
	detail := func(roles []Role) string {
		err := RequireLogin(e.home, roles)
		if err == nil {
			return ""
		}
		se := mustErr(t, err)
		if se.Class != "provider" || se.Reason != "login" || se.Exit != 4 {
			t.Fatalf("error = %+v", se)
		}
		return se.Detail
	}
	if got := detail(grok); got != "not signed in; run kogen provider login supergrok" {
		t.Fatal(got)
	}
	e.saveCreds("supergrok", e.supergrokCreds("expires_at", int64(0)))
	if got := detail(grok); got != "" {
		t.Fatal(got)
	}
	if got := detail([]Role{grokRole, fixtureRole}); got != "not signed in; run kogen provider login chatgpt" {
		t.Fatal(got)
	}
	e.saveCreds("supergrok", e.supergrokCreds("referrer", "borrowed"))
	if got := detail(grok); got != "saved login cannot be used; run kogen provider login supergrok" {
		t.Fatal(got)
	}
	e.saveCreds("chatgpt", map[string]any{"client_id": "oaiapp_test", "refresh_token": "refresh-token"})
	if got := detail([]Role{fixtureRole}); got != "saved login cannot be used; run kogen provider login chatgpt" {
		t.Fatal(got)
	}
	if len(f.authRequests()) != 0 || len(f.requests()) != 0 {
		t.Fatal("RequireLogin made a request")
	}
}

func TestCredentialsAreWrittenPrivatelyAndAtomically(t *testing.T) {
	old := syscall.Umask(0o022)
	defer syscall.Umask(old)
	home := t.TempDir()
	p, _ := Lookup("supergrok")
	if err := writeCredentials(home, p, credentials{"client_id": "x", "expires_at": int64(5)}); err != nil {
		t.Fatal(err)
	}
	mode := func(path string) os.FileMode {
		st, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		return st.Mode().Perm()
	}
	if mode(credentialsPath(home, p)) != 0o600 || mode(filepath.Join(home, ".kogen", "credentials")) != 0o700 || mode(filepath.Join(home, ".kogen")) != 0o700 {
		t.Fatal("modes are not 600/700/700 under umask 022")
	}
	entries, _ := os.ReadDir(filepath.Join(home, ".kogen", "credentials"))
	if len(entries) != 1 {
		t.Fatalf("temporary files remain: %v", entries)
	}
	// An existing .kogen with looser permissions is tightened.
	os.Chmod(filepath.Join(home, ".kogen"), 0o755)
	if err := writeCredentials(home, p, credentials{"client_id": "y"}); err != nil || mode(filepath.Join(home, ".kogen")) != 0o700 {
		t.Fatalf("not tightened: %v", err)
	}
}

func TestHostIDIsStable(t *testing.T) {
	home := t.TempDir()
	a, err := hostID(home)
	if err != nil || !strings.HasPrefix(a, "urn:uuid:") || len(a) != len("urn:uuid:")+36 {
		t.Fatalf("host id %q, %v", a, err)
	}
	if a[len("urn:uuid:")+14] != '4' {
		t.Fatal("not a version 4 UUID")
	}
	b, _ := hostID(home)
	data, _ := os.ReadFile(hostIDPath(home))
	if a != b || string(data) != a+"\n" {
		t.Fatalf("host id changed: %q %q %q", a, b, data)
	}
	os.WriteFile(hostIDPath(home), []byte("  custom-id \n"), 0o644)
	if c, _ := hostID(home); c != "custom-id" {
		t.Fatal(c)
	}
}

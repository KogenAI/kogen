package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/KogenAI/kogen-loop/provider"
	"github.com/KogenAI/kogen-loop/sys"
)

// K-CLAUDE-MANAGED-LOGIN: `provider login claude-code` on an interactive terminal signs in with
// Kogen's managed runtime; the terminal check and the real SetupToken (network, browser) are
// replaced through the package seams.

type managedLogin struct {
	home   string
	calls  int
	token  string
	err    error
	gotHom string
}

func newManagedLogin(t *testing.T, terminal bool) *managedLogin {
	t.Helper()
	m := &managedLogin{home: t.TempDir()}
	t.Setenv("HOME", m.home)
	oldSetup, oldTerm := setupToken, interactiveLogin
	t.Cleanup(func() { setupToken, interactiveLogin = oldSetup, oldTerm })
	setupToken = func(ctx context.Context, home string, out io.Writer) (string, error) {
		m.calls++
		m.gotHom = home
		return m.token, m.err
	}
	interactiveLogin = func() bool { return terminal }
	return m
}

func (m *managedLogin) run(t *testing.T, piped string) error {
	t.Helper()
	s := sys.New()
	client := provider.NewClient("kogen test")
	if piped != "" {
		client.Input = &provider.Input{Reader: strings.NewReader(piped)}
	}
	return login(s, client, "claude-code")
}

func (m *managedLogin) credential() string {
	return filepath.Join(m.home, ".kogen", "credentials", "claude-code.json")
}

func TestClaudeCodeTerminalLoginStoresSetupToken(t *testing.T) {
	m := newManagedLogin(t, true)
	m.token = "sk-ant-oat01-managed_token.value"
	if err := m.run(t, ""); err != nil {
		t.Fatal(err)
	}
	if m.calls != 1 || m.gotHom != m.home {
		t.Fatalf("SetupToken calls=%d home=%q, want 1 call with %q", m.calls, m.gotHom, m.home)
	}
	st, err := os.Stat(m.credential())
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm() != 0o600 {
		t.Fatalf("credential mode %v, want 600", st.Mode().Perm())
	}
	if got, ok := provider.ClaudeCodeToken(m.home); !ok || got != m.token {
		t.Fatalf("stored token %q (ok %v), want %q", got, ok, m.token)
	}
}

func TestClaudeCodePipedLoginSkipsSetupToken(t *testing.T) {
	m := newManagedLogin(t, false)
	m.token = "must-not-be-used"
	if err := m.run(t, "piped-token-abc123"); err != nil {
		t.Fatal(err)
	}
	if m.calls != 0 {
		t.Fatalf("SetupToken called %d times for piped input", m.calls)
	}
	if got, ok := provider.ClaudeCodeToken(m.home); !ok || got != "piped-token-abc123" {
		t.Fatalf("stored token %q (ok %v)", got, ok)
	}
	if _, err := os.Stat(filepath.Join(m.home, ".kogen", "claude-code")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("runtime directory exists after a piped login: %v", err)
	}
}

func TestClaudeCodeTerminalLoginFailureKeepsSavedToken(t *testing.T) {
	m := newManagedLogin(t, false)
	if err := m.run(t, "saved-token-keep"); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(m.credential())
	if err != nil {
		t.Fatal(err)
	}

	interactiveLogin = func() bool { return true }
	m.token = "leaked-secret-value"
	m.err = sys.Fail("executor", "unavailable", "cannot install Kogen's Claude Code: boom; run `kogen provider login claude-code` to retry", 1)
	err = m.run(t, "")
	if err == nil {
		t.Fatal("failed sign-in returned no error")
	}
	if m.calls != 1 {
		t.Fatalf("SetupToken calls=%d", m.calls)
	}
	var out bytes.Buffer
	orig := os.Stdout
	r, w, _ := os.Pipe()
	os.Stdout = w
	code := exitFor(err)
	w.Close()
	os.Stdout = orig
	io.Copy(&out, r)
	if code == 0 {
		t.Fatal("exit code 0 after a failed sign-in")
	}
	if !strings.Contains(out.String(), "run `kogen provider login claude-code` to retry") {
		t.Fatalf("no retry guidance: %q", out.String())
	}
	if strings.Contains(out.String(), m.token) {
		t.Fatalf("output carries the token: %q", out.String())
	}
	after, err := os.ReadFile(m.credential())
	if err != nil || !bytes.Equal(before, after) {
		t.Fatalf("saved credential changed: %v\nbefore %q\nafter  %q", err, before, after)
	}
}

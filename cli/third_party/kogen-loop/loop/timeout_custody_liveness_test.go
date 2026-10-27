package loop

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen-loop/tools"
)

func TestTimeoutCustodySessionContext(t *testing.T) {
	root := t.TempDir()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"c","type":"function","function":{"name":"shell","arguments":"{\"command\":\"trap 'echo term > term; exit 0' TERM; echo $$ > ready; while :; do :; done\"}"}}]},"finish_reason":"tool_calls"}]}`)
	}))
	defer srv.Close()
	session := sys.NewWith([]string{"HOME=" + t.TempDir(), "PATH=" + os.Getenv("PATH")}, root)
	s, err := NewSession(SessionConfig{Root: root, Role: provider.Role{Provider: "openai-compatible", Model: "local", BaseURL: srv.URL}, Session: session, Enabled: []string{tools.ShellTool}})
	if err != nil {
		t.Fatal(err)
	}
	// Library caller setting, deliberately not a SessionConfig option.
	s.tools.ShellTimeout = time.Second
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { _, err := s.Round(ctx, "run"); done <- err }()
	deadline := time.After(3 * time.Second)
	for {
		if _, err := os.Stat(filepath.Join(root, "ready")); err == nil {
			break
		}
		select {
		case err := <-done:
			t.Fatalf("returned before execution: %v", err)
		case <-deadline:
			t.Fatal("no shell readiness")
		case <-time.After(time.Millisecond):
		}
	}
	// Retain an owned zombie, parented by this test (not an orphan), so the
	// positive-timeout custody wait cannot truthfully finish before cancellation.
	data, err := os.ReadFile(filepath.Join(root, "ready"))
	if err != nil {
		t.Fatal(err)
	}
	pgid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		t.Fatal(err)
	}
	zombie := exec.Command("/bin/sh", "-c", "exit 0")
	zombie.SysProcAttr = &syscall.SysProcAttr{Setpgid: true, Pgid: pgid}
	if err := zombie.Start(); err != nil {
		t.Fatal(err)
	}
	defer zombie.Wait() // only reap after the stopped round returns
	termDeadline := time.After(3 * time.Second)
	for {
		if _, err := os.Stat(filepath.Join(root, "term")); err == nil {
			break
		}
		select {
		case err := <-done:
			t.Fatalf("premature feedback: %v", err)
		case <-termDeadline:
			t.Fatal("no timeout TERM")
		case <-time.After(time.Millisecond):
		}
	}
	cancel()
	select {
	case err := <-done:
		if err != context.Canceled {
			t.Fatal(err)
		}
	case <-time.After(7 * time.Second):
		t.Fatal("Session did not stop")
	}
	if len(s.input) != 0 {
		t.Fatal("stopped round persisted output")
	}
}

type custodyFake struct{}

func (custodyFake) Request(ctx context.Context, r Request) (*provider.Response, []any, error) {
	return &provider.Response{Items: []map[string]any{{"type": "function_call", "name": "shell", "arguments": "{}"}}}, r.Input, nil
}

func TestTimeoutCustodyHookPrecedence(t *testing.T) {
	for _, hook := range []string{"BeforeCall", "HandleCall", "AfterCall"} {
		ctx, cancel := context.WithCancel(context.Background())
		s := sys.NewWith(nil, t.TempDir())
		want := errors.New("hook owns this failure")
		fail := func() error { cancel(); s.Interrupt("SIGINT"); return want }
		h := Hooks{}
		switch hook {
		case "BeforeCall":
			h.BeforeCall = func(context.Context, tools.Call, []any) error { return fail() }
		case "HandleCall":
			h.HandleCall = func(context.Context, tools.Call) (Handled, error) { return Handled{}, fail() }
		case "AfterCall":
			h.HandleCall = func(context.Context, tools.Call) (Handled, error) { return Handled{Handled: true}, nil }
			h.AfterCall = func(context.Context, tools.Call, tools.Output, bool, []any) error { return fail() }
		}
		_, err := Run(ctx, Round{Tools: &tools.Tools{Session: s}}, nil, custodyFake{}, h)
		cancel()
		if err != want {
			t.Fatalf("%s: %v", hook, err)
		}
	}
}

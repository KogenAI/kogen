package loop

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"regexp"
	"sync/atomic"
	"testing"
	"time"

	"kogen-loop/api"
	"kogen-loop/provider"
	"kogen-loop/sys"
)

// The session's tool.result carries handle_yielded for a yielding command and bound for the
// retrieval that reaches its bound, with the retrieval repeating the command's spawn instant.
func TestSessionShellWaitEventsCarryYieldAndBound(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	handle := regexp.MustCompile(`handle\\":\\"([0-9a-f]+)`)
	var n atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		w.Header().Set("Content-Type", "application/json")
		var name, args string
		switch n.Add(1) {
		case 1:
			name, args = "shell", `{\"command\":\": > ready; while :; do sleep .05; done\"}`
		case 2:
			m := handle.FindSubmatch(body)
			if m == nil {
				t.Errorf("no handle in %s", body)
				m = [][]byte{nil, nil}
			}
			name, args = "shell", fmt.Sprintf(`{\"handle\":\"%s\"}`, m[1])
		default:
			name, args = "finish", `{\"summary\":\"done\"}`
		}
		fmt.Fprintf(w, `{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"c%d","type":"function","function":{"name":"%s","arguments":"%s"}}]},"finish_reason":"tool_calls"}]}`, n.Load(), name, args)
	}))
	defer srv.Close()
	var events []api.Event
	s, err := NewSession(SessionConfig{
		Root: root, Role: provider.Role{Provider: "openai-compatible", Model: "local", BaseURL: srv.URL},
		Session: sys.NewWith([]string{"HOME=" + t.TempDir(), "PATH=" + os.Getenv("PATH")}, root),
		Emit:    func(e api.Event) { events = append(events, e) },
	})
	if err != nil {
		t.Fatal(err)
	}
	s.tools.ShellAfter = func(wait time.Duration) <-chan time.Time {
		if wait == 45*time.Second {
			return yieldAfter(t, root, "ready")(wait)
		}
		fire := make(chan time.Time, 1)
		fire <- time.Now()
		return fire
	}
	res, err := s.Round(context.Background(), "go")
	if err != nil || res.Ending != EndTerminal {
		t.Fatalf("%+v %v", res, err)
	}
	var waits []map[string]any
	for _, e := range events {
		if e.Type != api.EventToolResult {
			continue
		}
		w, ok := e.Fields["shell_wait"].(map[string]any)
		if !ok {
			t.Fatalf("tool.result without shell_wait: %v", e.Fields)
		}
		waits = append(waits, w)
	}
	if len(waits) != 2 {
		t.Fatalf("shell waits %v", waits)
	}
	if waits[0]["ended_by"] != api.ShellWaitHandleYielded || waits[1]["ended_by"] != api.ShellWaitBound {
		t.Errorf("ended_by %v then %v", waits[0]["ended_by"], waits[1]["ended_by"])
	}
	spawned, _ := waits[0]["spawned"].(string)
	if spawned == "" || waits[1]["spawned"] != spawned {
		t.Errorf("spawned %v then %v", waits[0]["spawned"], waits[1]["spawned"])
	}
}

package loop

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/KogenAI/kogen-loop/api"
	"github.com/KogenAI/kogen-loop/provider"
	"github.com/KogenAI/kogen-loop/sys"
	"github.com/KogenAI/kogen-loop/tools"
)

// On a controlled clock, each tool.result's elapsed_ms is its own call's time: two probe
// calls of one response report the 200 and 1200 ms they advanced the clock by, and a read, a
// refused and a malformed shell call and an unknown tool report 0.
func TestSessionToolResultElapsedUsesTheToolsClock(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	if err := os.WriteFile(root+"/f.txt", []byte("text"), 0o644); err != nil {
		t.Fatal(err)
	}
	var n atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		if strings.Contains(string(body), "elapsed_ms") {
			t.Errorf("request body mentions elapsed_ms: %s", body)
		}
		w.Header().Set("Content-Type", "application/json")
		type c struct{ name, args string }
		var calls []c
		if n.Add(1) == 1 {
			calls = []c{
				{"probe", `{\"command\":\"200\"}`}, {"probe", `{\"command\":\"1200\"}`},
				{"read_file", `{\"path\":\"f.txt\"}`}, {"shell", `{\"command\":\"pkill -f nothing\"}`},
				{"shell", `{}`}, {"l_no_such_tool", `{}`},
			}
		} else {
			calls = []c{{"finish", `{\"summary\":\"done\"}`}}
		}
		var parts []string
		for i, x := range calls {
			parts = append(parts, fmt.Sprintf(`{"id":"c%d","type":"function","function":{"name":"%s","arguments":"%s"}}`, i, x.name, x.args))
		}
		fmt.Fprintf(w, `{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[%s]},"finish_reason":"tool_calls"}]}`, strings.Join(parts, ","))
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
	now := time.Date(2026, 11, 5, 10, 0, 0, 0, time.UTC)
	s.tools.Now = func() time.Time { return now }
	s.tools.Enabled = append(s.tools.Enabled, tools.ProbeTool)
	s.tools.Probe = func(command string, _ any) (string, error) {
		var ms int
		fmt.Sscan(command, &ms)
		now = now.Add(time.Duration(ms) * time.Millisecond)
		return "probe ran " + command + " ms", nil
	}
	res, err := s.Round(context.Background(), "go")
	if err != nil || res.Ending != EndTerminal {
		t.Fatalf("%+v %v", res, err)
	}
	want := map[string]int64{"c0": 200, "c1": 1200, "c2": 0, "c3": 0, "c4": 0, "c5": 0}
	got := map[string]int64{}
	for _, e := range events {
		if e.Type != api.EventToolResult {
			continue
		}
		ms, ok := e.Fields["elapsed_ms"].(int64)
		if !ok {
			t.Fatalf("elapsed_ms %T %v in %v", e.Fields["elapsed_ms"], e.Fields["elapsed_ms"], e.Fields)
		}
		got[fmt.Sprint(e.Fields["call_id"])] = ms
	}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("elapsed_ms %v, want %v", got, want)
	}
}

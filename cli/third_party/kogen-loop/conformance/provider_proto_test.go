package conformance

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// refusal is a message whose content parts are the given (type, text) pairs in order.
func refusalMessage(parts ...[2]string) map[string]any {
	var content []any
	for _, p := range parts {
		if p[0] == "refusal" {
			content = append(content, map[string]any{"type": "refusal", "refusal": p[1]})
		} else {
			content = append(content, map[string]any{"type": "output_text", "text": p[1], "annotations": []any{}})
		}
	}
	return map[string]any{"type": "message", "id": "msg-fixture", "role": "assistant", "status": "completed", "content": content}
}

// TestProviderProtoRefusalClaim: a valid completion whose message carries refusal parts is a
// no_call ending whose claim keeps them, in content order.
func TestProviderProtoRefusalClaim(t *testing.T) {
	const refused = "I cannot help with that request."
	cases := []struct {
		name  string
		items []map[string]any
		claim string
	}{
		{"refusal only", []map[string]any{refusalMessage([2]string{"refusal", refused})}, refused},
		{"text then refusal", []map[string]any{refusalMessage([2]string{"output_text", "Here is the part I can do."}, [2]string{"refusal", refused})},
			"Here is the part I can do.\n" + refused},
		{"refusal then text", []map[string]any{refusalMessage([2]string{"refusal", refused}, [2]string{"output_text", "Anything else?"})},
			refused + "\nAnything else?"},
		{"across messages", []map[string]any{message("First."), refusalMessage([2]string{"refusal", refused})}, "First.\n" + refused},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			w := newWorld(t).signIn()
			f := newFakeProvider(t, []exchange{{ID: "resp-1", Items: c.items, Usage: fullUsage(4, 0, 2, 0)}})
			r := runCLI(t, w, f, w.task(nil))
			if r.exit != 0 {
				t.Fatalf("exit %d: %s", r.exit, r.stderr)
			}
			ended := r.first("round.ended")
			if ended == nil || ended["ending"] != "no_call" || ended["claim"] != c.claim || ended["terminal_tool"] != nil {
				t.Fatalf("round.ended = %v; want no_call with claim %q", ended, c.claim)
			}
			if r.first("error") != nil || len(f.requests()) != 1 {
				t.Fatalf("error %v, %d requests", r.first("error"), len(f.requests()))
			}
			if end := r.events[len(r.events)-1]; end["status"] != "ended" {
				t.Fatalf("session.ended %v", end)
			}
		})
	}
}

func shellCall(id, command string) map[string]any {
	return call(id, "shell", map[string]any{"command": command})
}

// TestProviderProtoDuplicateCalls: two function calls with one call_id reject the whole
// effective batch (invalid response, one retry) before either runs; distinct IDs stay valid.
func TestProviderProtoDuplicateCalls(t *testing.T) {
	const appendX = "printf x >> counter.txt"
	dup := []map[string]any{shellCall("call_1", appendX), shellCall("call_1", appendX)}
	conflict := []map[string]any{shellCall("call_1", appendX), shellCall("call_1", "printf y >> counter.txt")}
	distinct := []map[string]any{shellCall("call_1", appendX), shellCall("call_2", appendX)}
	finish := call("call_9", "finish", map[string]any{"summary": "done"})

	counter := func(w *world) string {
		data, err := os.ReadFile(filepath.Join(w.root, "counter.txt"))
		if err != nil {
			return ""
		}
		return string(data)
	}
	rejected := []struct {
		name   string
		script []exchange
	}{
		{"done items", []exchange{{Items: dup}, {Items: dup}}},
		{"conflicting arguments", []exchange{{Items: conflict}, {Items: conflict}}},
		{"final output", []exchange{{Output: dup}, {Output: dup}}},
		{"final output over distinct done items", []exchange{{Items: distinct, Output: dup}, {Items: distinct, Output: dup}}},
		{"after other calls", []exchange{{Items: append([]map[string]any{shellCall("call_0", appendX)}, dup...)}, {Items: dup}}},
	}
	for _, c := range rejected {
		t.Run("rejected/"+c.name, func(t *testing.T) {
			w := newWorld(t).signIn()
			f := newFakeProvider(t, append(c.script, exchange{Items: []map[string]any{finish}}))
			r := runCLI(t, w, f, w.task(nil))
			if r.exit != 1 {
				t.Fatalf("exit %d, want 1 (stderr: %s)", r.exit, r.stderr)
			}
			e := r.first("error")
			if e == nil || e["class"] != "provider" || e["reason"] != "invalid_response" {
				t.Fatalf("error = %v", e)
			}
			if n := len(f.requests()); n != 2 {
				t.Fatalf("%d requests, want the first and one retry", n)
			}
			if got := counter(w); got != "" {
				t.Fatalf("counter.txt = %q: a duplicate batch ran", got)
			}
			if len(r.all("tool.result")) != 0 || r.first("round.ended") != nil {
				t.Fatalf("events %v", r.types())
			}
		})
	}

	t.Run("recovered retry runs only the valid batch", func(t *testing.T) {
		w := newWorld(t).signIn()
		f := newFakeProvider(t, []exchange{{Items: dup}, {Items: distinct}, {Items: []map[string]any{finish}}})
		r := runCLI(t, w, f, w.task(nil))
		if r.exit != 0 || len(f.requests()) != 3 {
			t.Fatalf("exit %d, %d requests: %s", r.exit, len(f.requests()), r.stderr)
		}
		if got := counter(w); got != "xx" {
			t.Fatalf("counter.txt = %q, want xx", got)
		}
	})

	t.Run("distinct IDs control", func(t *testing.T) {
		w := newWorld(t).signIn()
		f := newFakeProvider(t, []exchange{{Items: distinct}, {Items: []map[string]any{finish}}})
		r := runCLI(t, w, f, w.task(nil))
		if r.exit != 0 || len(f.requests()) != 2 {
			t.Fatalf("exit %d, %d requests: %s", r.exit, len(f.requests()), r.stderr)
		}
		if got := counter(w); got != "xx" {
			t.Fatalf("counter.txt = %q, want xx", got)
		}
		if ended := r.first("round.ended"); ended == nil || ended["ending"] != "terminal" {
			t.Fatalf("round.ended = %v", ended)
		}
		if !strings.Contains(string(mustJSON(t, f.requests()[1]["input"])), `"call_id":"call_2"`) {
			t.Fatal("the second request does not answer both calls")
		}
	})
}

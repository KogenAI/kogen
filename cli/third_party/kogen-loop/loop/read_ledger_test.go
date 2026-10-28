package loop

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"kogen-loop/provider"
	"kogen-loop/tools"
)

func ledgerCall(name, args string) map[string]any {
	return map[string]any{"type": "function_call", "call_id": "c", "name": name, "arguments": args}
}
func ledgerRun(t *testing.T, l *ReadLedger, dir string, calls ...map[string]any) (*scriptRequester, Result) {
	t.Helper()
	rq := &scriptRequester{script: [][]map[string]any{calls, call("finish")}}
	res, err := Run(context.Background(), Round{ReadLedger: l, Tools: &tools.Tools{Root: dir, Enabled: []string{tools.ReadFileTool, tools.ViewImageTool}}}, []any{userMsg("old")}, rq, Hooks{})
	if err != nil {
		t.Fatal(err)
	}
	return rq, res
}
func ledgerContent(t *testing.T, l *ReadLedger) (map[string]any, map[string]any) {
	t.Helper()
	in, event := l.Continuation(nil)
	var obj map[string]any
	if err := json.Unmarshal([]byte(in[0].(map[string]any)["content"].(string)), &obj); err != nil {
		t.Fatal(err)
	}
	return obj, event
}

type ledgerBudgetRequester struct{ script scriptRequester }

func (r *ledgerBudgetRequester) Request(ctx context.Context, req Request) (*provider.Response, []any, error) {
	if _, err := (FailOverBudget{InputBudgetBytes: 65536}).Prepare(ctx, req); err != nil {
		return nil, nil, err
	}
	return r.script.Request(ctx, req)
}

func TestReadLedger(t *testing.T) {
	t.Run("text_metadata", func(t *testing.T) {
		dir := t.TempDir()
		os.WriteFile(filepath.Join(dir, "a"), []byte(" \n  error: real\n"+strings.Repeat("界", 81)+"\n"), 0600)
		os.WriteFile(filepath.Join(dir, "empty"), nil, 0600)
		l := NewReadLedger()
		ledgerRun(t, l, dir, ledgerCall("read_file", `{"path":"a","start_line":2,"end_line":3}`), ledgerCall("read_file", `{"path":"empty"}`), ledgerCall("read_file", `{"path":"missing"}`), ledgerCall("read_file", `{"path":"a","start_line":3}`))
		obj, _ := ledgerContent(t, l)
		e := obj["entries"].([]any)
		if len(e) != 3 {
			t.Fatal(obj)
		}
		a := e[0].(map[string]any)
		sum := sha256.Sum256([]byte("2\t  error: real\n3\t" + strings.Repeat("界", 81)))
		if a["sha256"] != fmt.Sprintf("%x", sum) || a["start_line"] != float64(2) || a["end_line"] != float64(3) || a["note"] != "error: real" {
			t.Fatal(a)
		}
		empty := e[1].(map[string]any)
		sum = sha256.Sum256(nil)
		if empty["sha256"] != fmt.Sprintf("%x", sum) || empty["start_line"] != float64(0) || empty["end_line"] != float64(0) || empty["note"] != "" {
			t.Fatal(empty)
		}
		if e[2].(map[string]any)["note"] != strings.Repeat("界", 80) {
			t.Fatal(e[2])
		}
	})
	t.Run("reset_two_reads", func(t *testing.T) {
		dir := t.TempDir()
		os.WriteFile(filepath.Join(dir, "a"), []byte("first\nsecond"), 0600)
		l := NewReadLedger()
		ledgerRun(t, l, dir, ledgerCall("read_file", `{"path":"a","start_line":1,"end_line":1}`), ledgerCall("read_file", `{"path":"a","start_line":2}`))
		base := []any{userMsg("fresh")}
		in, _ := l.Continuation(base)
		rq := &scriptRequester{script: [][]map[string]any{call("finish")}}
		_, err := Run(context.Background(), Round{ReadLedger: l}, in, rq, Hooks{})
		if err != nil || len(rq.requests[0]) != 2 || !reflect.DeepEqual(base, []any{userMsg("fresh")}) {
			t.Fatal(rq, err)
		}
		s := marshal(t, rq.requests[0])
		if strings.Contains(s, `1\tfirst`) || strings.Contains(s, "old") {
			t.Fatal(s)
		}
		obj, _ := ledgerContent(t, l)
		if len(obj["entries"].([]any)) != 2 {
			t.Fatal(obj)
		}
	})
	t.Run("image_reference", func(t *testing.T) {
		dir := t.TempDir()
		b, _ := base64.StdEncoding.DecodeString("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")
		os.WriteFile(filepath.Join(dir, "a.png"), b, 0600)
		l := NewReadLedger()
		ledgerRun(t, l, dir, ledgerCall("view_image", `{"path":"a.png"}`))
		obj, _ := ledgerContent(t, l)
		e := obj["entries"].([]any)[0].(map[string]any)
		sum := sha256.Sum256(b)
		if len(e) != 3 || e["sha256"] != fmt.Sprintf("%x", sum) || e["path"] != "a.png" {
			t.Fatal(e)
		}
	})
	t.Run("cap_fifo", func(t *testing.T) {
		out := tools.Output{Parts: []any{map[string]any{"text": `{"sha256":"x"}`}}}
		for _, n := range []int{8191, 8192, 8193} {
			l := NewReadLedger()
			l.record(ledgerCallObject("view_image", `{"path":""}`), out, "")
			overhead := len(l.content())
			l = NewReadLedger()
			path := strings.Repeat("x", n-overhead)
			l.record(ledgerCallObject("view_image", fmt.Sprintf(`{"path":%q}`, path)), out, "")
			obj, _ := ledgerContent(t, l)
			entries := obj["entries"].([]any)
			if n <= 8192 {
				if len(l.content()) != n || len(entries) != 1 || obj["dropped"] != float64(0) {
					t.Fatal(n, obj)
				}
			} else if len(entries) != 0 || obj["dropped"] != float64(1) {
				t.Fatal(n, obj)
			}
		}
		l := NewReadLedger()
		l.record(ledgerCallObject("view_image", fmt.Sprintf(`{"path":%q}`, strings.Repeat("z", 9000))), out, "")
		for i := 0; i < 200; i++ {
			l.record(ledgerCallObject("view_image", `{"path":"same"}`), out, "")
		}
		obj, _ := ledgerContent(t, l)
		if obj["dropped"].(float64) <= 1 || len(l.content()) > 8192 {
			t.Fatal(obj)
		}
	})
	t.Run("reset_events", func(t *testing.T) {
		l := NewReadLedger()
		a, e := l.Continuation(nil)
		b, f := l.Continuation(nil)
		if !reflect.DeepEqual(a, b) || !reflect.DeepEqual(e, f) || e["bytes"] != len(a[0].(map[string]any)["content"].(string)) || e["entries"] != 0 {
			t.Fatal(a, e, f)
		}
		dir := t.TempDir()
		os.WriteFile(filepath.Join(dir, "a"), []byte("hi"), 0600)
		ledgerRun(t, l, dir, ledgerCall("read_file", `{"path":"a"}`))
		_, e = l.Continuation(nil)
		if e["entries"] != 1 {
			t.Fatal(e)
		}
	})
	t.Run("off_identical", func(t *testing.T) {
		dir := t.TempDir()
		rq, res := ledgerRun(t, nil, dir, ledgerCall("read_file", `{"path":"missing"}`))
		if got := marshal(t, rq.requests[1]); got != `[{"content":"old","role":"user"},{"arguments":"{\"path\":\"missing\"}","call_id":"c","name":"read_file","type":"function_call"},{"call_id":"c","output":"error: missing does not exist","type":"function_call_output"}]` {
			t.Fatal(got)
		}
		if res.Ending != EndTerminal || res.Requests != 2 {
			t.Fatal(res)
		}
	})
	t.Run("budget_unchanged", func(t *testing.T) {
		dir := t.TempDir()
		if err := os.WriteFile(filepath.Join(dir, "a"), []byte(strings.Repeat("x", 10000)), 0600); err != nil {
			t.Fatal(err)
		}
		l := NewReadLedger()
		rq := &ledgerBudgetRequester{script: scriptRequester{script: [][]map[string]any{{ledgerCall("read_file", `{"path":"a"}`)}}}}
		base := budgetReq(60000)
		_, err := Run(context.Background(), Round{ReadLedger: l, Role: base.Role, Instructions: base.Instructions, Tools: &tools.Tools{Root: dir, Enabled: []string{tools.ReadFileTool}}}, nil, rq, Hooks{})
		obj, event := ledgerContent(t, l)
		if err == nil || !strings.Contains(err.Error(), "context_budget_exceeded") || len(rq.script.requests) != 1 || len(obj["entries"].([]any)) != 1 || event["dropped"] != 0 {
			t.Fatal(err, obj, event, len(rq.script.requests))
		}
	})
}
func ledgerCallObject(name, args string) tools.Call {
	return tools.Calls([]map[string]any{ledgerCall(name, args)})[0]
}

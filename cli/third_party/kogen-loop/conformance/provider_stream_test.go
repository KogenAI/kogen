package conformance

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"kogen-loop/api"
	"kogen-loop/loop"
	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen-loop/tools"
)

type streamEvidence struct {
	Requests []streamRequest
	Effects  streamEffects
	Records  []map[string]any
	Resume   streamResumeObservation
}

func TestProviderStreamConformance(t *testing.T) {
	var directChat, resume streamEvidence
	t.Run("ChatGPT_Direct", func(t *testing.T) {
		w := streamWorld(t, false)
		f := newStreamFake(t, "/v1/responses", streamRefusal("invalid_parameter", "prompt_cache_key", "prompt_cache_key is not supported on this model"), streamReply{Items: []map[string]any{call("c", "write_file", map[string]any{"path": "x.txt", "content": "observed"})}}, streamReply{Items: []map[string]any{message("done")}})
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		obs := &recorder{}
		client := provider.NewClient("test")
		d := &loop.Direct{Client: client, Session: sys.NewWith(streamEnv(w, f), w.root), CacheID: provider.NewCacheID(), Cache: client.Cache, Observer: obs}
		rd := roundWith(t, w)
		rd.Role = provider.Role{Provider: "chatgpt", Model: "gpt-6.1-sol", Effort: "high"}
		rd.Definitions = tools.AsAny(tools.Defs("write_file"), nil)
		res, err := loop.Run(ctx, rd, []any{userMessage("go")}, d, loop.Hooks{})
		if err != nil {
			t.Fatal(err)
		}
		if res.Requests != 2 || res.Ending != loop.EndNoCall || !reflect.DeepEqual(streamClone(res.Response.Items[0]["content"]), []any{map[string]any{"type": "output_text", "text": "done", "annotations": []any{}}}) {
			t.Fatal(res)
		}
		b, err := os.ReadFile(filepath.Join(w.root, "x.txt"))
		if err != nil || string(b) != "observed" {
			t.Fatal("missing tool output")
		}
		reqs := f.captured(t)
		id, _ := reqs[0].Body["prompt_cache_key"].(string)
		if err := checkStreamHeaders(reqs, []bool{true, false, false}, id); err != nil {
			t.Fatal(err)
		}
		if err := checkStreamRetry(reqs[0].Body, reqs[1].Body); err != nil {
			t.Fatal(err)
		}
		if len(obs.records) != 3 || obs.records[0]["usage_state"] != "unknown" {
			t.Fatal("attempts")
		}
		if err := checkStreamChatTool(reqs[2].Body); err != nil {
			t.Fatal(err)
		}
		directChat = streamEvidence{Requests: reqs}
	})
	t.Run("ChatGPT_CLI_Transcript", func(t *testing.T) {
		w := streamWorld(t, false)
		f := newStreamFake(t, "/v1/responses", streamRefusal("invalid_parameter", "prompt_cache_key", "prompt_cache_key is not supported on this model"), streamReply{Items: []map[string]any{call("c", "write_file", map[string]any{"path": "x.txt", "content": "observed"})}}, streamReply{Items: []map[string]any{message("done")}}, streamRefusal("invalid_parameter", "prompt_cache_key", "prompt_cache_key is not supported on this model"), streamReply{Items: []map[string]any{message("restored")}})
		dir := filepath.Join(w.home, "transcript")
		over := map[string]any{"role": map[string]any{"provider": "chatgpt", "model": "gpt-6.1-sol", "effort": "high", "base_url": ""}, "prompt": "start"}
		first := streamCLI(t, w, f, sessionTask(w, dir, false, over))
		f.mu.Lock()
		firstHTTP := len(f.requests)
		f.mu.Unlock()
		if firstHTTP != 3 {
			t.Fatalf("first process HTTP requests=%d", firstHTTP)
		}
		tr := transcriptOf(t, dir)
		stored := streamClone(tr["input"])
		id, _ := tr["session_id"].(string)
		over["prompt"] = "feedback: check again"
		second := streamCLI(t, w, f, sessionTask(w, dir, true, over))
		for i, r := range []result{first, second} {
			wantHTTP, wantLogical := 3, 2
			if i == 1 {
				wantHTTP, wantLogical = 2, 1
			}
			if r.exit != 0 || len(r.all("request.started")) != wantLogical || len(r.all("request.attempt")) != wantHTTP {
				t.Fatalf("process %d: %v %s", i, r.events, r.stderr)
			}
			if r.first("session.started")["session_id"] != id {
				t.Fatal("start identity")
			}
			wantClaim := "done"
			if i == 1 {
				wantClaim = "restored"
			}
			if r.first("round.ended")["ending"] != "no_call" || r.first("round.ended")["claim"] != wantClaim {
				t.Fatal("ending")
			}
		}
		if second.first("session.started")["resumed"] != true {
			t.Fatal("not resumed")
		}
		reqs := f.captured(t)
		if err := checkStreamHeaders(reqs, []bool{true, false, false, true, false}, id); err != nil {
			t.Fatal(err)
		}
		for _, tr := range []map[string]any{tr, transcriptOf(t, dir)} {
			if len(tr) != 7 {
				t.Fatalf("unexpected transcript fields: %v", tr)
			}
			for _, k := range []string{"protocol", "session_id", "role", "instructions_sha256", "definitions_sha256", "terminal", "input"} {
				if _, ok := tr[k]; !ok {
					t.Fatalf("transcript missing %s", k)
				}
			}
		}
		for p, mode := range map[string]os.FileMode{dir: 0700, filepath.Join(dir, "session.json"): 0600} {
			st, err := os.Stat(p)
			if err != nil || st.Mode().Perm() != mode {
				t.Fatalf("transcript permissions: %v %v", st, err)
			}
		}
		b, err := os.ReadFile(filepath.Join(w.root, "x.txt"))
		if err != nil || string(b) != "observed" {
			t.Fatal("tool effect")
		}
		if err := checkStreamChatTool(reqs[2].Body); err != nil {
			t.Fatal(err)
		}
		resumeObservation := streamResumeObservation{Requests: reqs, TranscriptID: id, Starts: []map[string]any{first.first("session.started"), second.first("session.started")}, Stored: stored.([]any)}
		if err := checkStreamResume(resumeObservation); err != nil {
			t.Fatal(err)
		}
		resume = streamEvidence{Requests: reqs, Resume: resumeObservation}
	})
	var valid, validDirect, invalid streamEvidence
	for _, facade := range []string{"Direct", "Session", "CLI"} {
		for _, reason := range []string{"end_turn", "tool_use", "invalid_later"} {
			if facade == "Direct" && reason == "tool_use" {
				continue
			}
			t.Run("Anthropic_"+facade+"_"+reason, func(t *testing.T) {
				evidence := runStreamAnthropic(t, facade, reason)
				if reason == "invalid_later" {
					invalid = evidence
				} else if reason == "end_turn" {
					valid = evidence
					if facade == "Direct" {
						validDirect = evidence
					}
				}
			})
		}
	}
	t.Run("negative_controls", func(t *testing.T) { streamNegativeControls(t, directChat, resume, valid, validDirect, invalid) })
}
func runStreamAnthropic(t *testing.T, facade, reason string) streamEvidence {
	t.Helper()
	bad := reason == "invalid_later"
	stop := reason
	if bad {
		stop = "end_turn"
	}
	w := streamWorld(t, true)
	replies := []streamReply{streamMessages(stop, bad, false)}
	if !bad {
		replies = append(replies, streamMessages("end_turn", false, true))
	}
	f := newStreamFake(t, "/v1/messages", replies...)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	role := provider.Role{Provider: "anthropic", Model: "claude-opus-5-5", Effort: "high"}
	client := provider.NewClient("test")
	session := sys.NewWith(streamEnv(w, f), w.root)
	var events []map[string]any
	var records []map[string]any
	var res loop.Result
	var err error
	o := streamEffects{}
	if facade == "Direct" {
		obs := &recorder{}
		d := &loop.Direct{Client: client, Session: session, CacheID: provider.NewCacheID(), Cache: client.Cache, Observer: obs}
		rd := roundWith(t, w)
		rd.Role = role
		rd.Definitions = tools.AsAny(tools.Defs("shell"), nil)
		rd.Tools.Session = session
		hooks := loop.Hooks{BeforeRequest: func(context.Context, []any) error { o.Logical++; return nil }, AfterResponse: func(_ context.Context, r *provider.Response, _ []any) error {
			o.Exposed += len(tools.Calls(r.Items))
			return nil
		}, BeforeCall: func(_ context.Context, c tools.Call, _ []any) error {
			o.Hooks = append(o.Hooks, "before:"+fmt.Sprint(c.CallID()))
			return nil
		}, HandleCall: func(_ context.Context, c tools.Call) (loop.Handled, error) {
			o.Hooks = append(o.Hooks, "handle:"+fmt.Sprint(c.CallID()))
			return loop.Handled{}, nil
		}, AfterCall: func(_ context.Context, c tools.Call, out tools.Output, _ bool, _ []any) error {
			o.Hooks = append(o.Hooks, "after:"+fmt.Sprint(c.CallID()))
			if out.Text != "exit status: 0\n" {
				t.Errorf("actual tool output %q", out.Text)
			}
			return nil
		}}
		res, err = loop.Run(ctx, rd, []any{userMessage("go")}, d, hooks)
		records = obs.records
		if err == nil {
			o.Rounds = 1
		}
	} else if facade == "Session" {
		s, e := loop.NewSession(loop.SessionConfig{Root: w.root, Role: role, Client: client, Session: session, Enabled: []string{"shell"}, Emit: func(e api.Event) {
			b, _ := json.Marshal(e)
			var m map[string]any
			json.Unmarshal(b, &m)
			events = append(events, m)
		}})
		if e != nil {
			t.Fatal(e)
		}
		res, err = s.Round(ctx, "go")
	} else {
		task := w.task(map[string]any{"role": map[string]any{"provider": "anthropic", "model": role.Model, "effort": "high", "base_url": ""}, "tools": []any{"shell"}, "deadline_seconds": 15})
		r := streamCLI(t, w, f, task)
		events = r.events
		if bad {
			if r.exit != 1 {
				t.Fatal("invalid CLI exit", r.exit)
			}
			e := r.first("error")
			if e == nil || e["class"] != "provider" || e["reason"] != "invalid_response" {
				t.Fatal("CLI typed error", e)
			}
		} else if r.exit != 0 {
			t.Fatalf("CLI: %v %s", r.events, r.stderr)
		}
	}
	if facade != "CLI" {
		if bad {
			se, ok := sys.AsError(err)
			if !ok || se.Class != "provider" || se.Reason != "invalid_response" || res.Response != nil {
				t.Fatalf("invalid response/error: %v %v", res, err)
			}
		} else {
			if err != nil {
				t.Fatal(err)
			}
			if res.Ending != loop.EndNoCall || res.Requests != 2 || res.Response == nil || !reflect.DeepEqual(streamClone(res.Response.Items[0]["content"]), []any{map[string]any{"type": "output_text", "text": "done"}}) {
				t.Fatal(res)
			}
		}
	}
	for _, e := range events {
		switch e["type"] {
		case "request.started":
			o.Logical++
		case "request.attempt":
			records = append(records, e["record"].(map[string]any))
		case "round.ended":
			o.Rounds++
			if e["ending"] != "no_call" || e["claim"] != "done" {
				t.Fatal("ending", e)
			}
		case "tool.call":
			o.Calls = append(o.Calls, fmt.Sprint(e["call_id"]))
			o.Events = append(o.Events, "call:"+fmt.Sprint(e["call_id"]))
		case "tool.result":
			o.Results = append(o.Results, fmt.Sprint(e["call_id"]))
			o.Events = append(o.Events, "result:"+fmt.Sprint(e["call_id"]))
			if e["result_sha256"] != sha("exit status: 0\n") || e["bytes"] != float64(len("exit status: 0\n")) {
				t.Fatal("tool result", e)
			}
		}
	}
	streamRedacted(t, events)
	streamRedacted(t, records)
	reqs := f.captured(t)
	o.Requests = len(reqs)
	o.Attempts = len(records)
	for _, name := range []string{"b", "a"} {
		b, e := os.ReadFile(filepath.Join(w.root, name+".log"))
		if e != nil && !os.IsNotExist(e) {
			t.Fatal(e)
		}
		o.Files = append(o.Files, string(b))
		if bad && !os.IsNotExist(e) {
			t.Fatal("invalid side effect exists")
		}
	}
	if err := checkStreamEffects(o, bad, facade == "Direct"); err != nil {
		t.Fatalf("%v: %+v", err, o)
	}
	if bad {
		if err := checkStreamMarker(records[0], nil, false); err != nil {
			t.Fatal(err)
		}
	} else {
		if err := checkStreamReplay(reqs[1].Body); err != nil {
			t.Fatalf("%v: %s", err, mustJSON(t, reqs[1].Body))
		}
		if err := checkStreamMarker(records[0], stop, stop == "end_turn"); err != nil {
			t.Fatal(err)
		}
		if err := checkStreamMarker(records[1], "end_turn", false); err != nil {
			t.Fatal(err)
		}
	}
	return streamEvidence{Requests: reqs, Effects: o, Records: records}
}

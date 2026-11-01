package shape

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"testing"
)

// forceWire is one provider route the scripted provider can speak: how the shape role is
// configured, how an answer is rendered on that wire, and what its tool_choice looks like.
type forceWire struct {
	name      string
	provider  string
	configure func(f *shpFx)
	// answer is one assistant answer: optional prose and any function calls (shpCall items).
	answer func(text string, calls ...map[string]any) shpStep
	// auto and forced are the tool_choice values of an ordinary and of a forced request.
	auto   any
	forced func(tool string) any
}

// toolChoice is the decoded tool_choice of a captured request.
func (w *forceWire) toolChoice(req map[string]any) any { return req["tool_choice"] }

var (
	responsesWire = &forceWire{
		name: "responses", provider: "chatgpt", configure: func(*shpFx) {},
		answer: func(text string, calls ...map[string]any) shpStep {
			var items []map[string]any
			if text != "" {
				items = append(items, map[string]any{"type": "message", "id": "m", "role": "assistant", "content": []any{map[string]any{"type": "output_text", "text": text}}})
			}
			return shpAnswer(append(items, calls...)...)
		},
		auto:   "auto",
		forced: func(tool string) any { return map[string]any{"type": "function", "name": tool} },
	}
	chatWire = &forceWire{
		name: "chat", provider: "openai-compatible",
		configure: func(f *shpFx) {
			f.t.Helper()
			f.write(".kogen/project.yaml", f.read(".kogen/project.yaml")+"models:\n  shape: {provider: openai-compatible, model: local-model, effort: high, base_url: '"+f.Prov.srv.URL+"/v1'}\n")
			f.git("add", ".kogen/project.yaml")
			f.git("commit", "-qm", "chat completions shape role")
		},
		answer: func(text string, calls ...map[string]any) shpStep {
			message := map[string]any{"role": "assistant", "content": nil}
			finish := "stop"
			if text != "" {
				message["content"] = text
			}
			if len(calls) > 0 {
				finish = "tool_calls"
				var wire []any
				for _, c := range calls {
					wire = append(wire, map[string]any{"id": c["call_id"], "type": "function", "function": map[string]any{"name": c["name"], "arguments": c["arguments"]}})
				}
				message["tool_calls"] = wire
			}
			body := map[string]any{"id": "chatcmpl-fixture", "model": "local-model", "choices": []any{map[string]any{"message": message, "finish_reason": finish}},
				"usage": map[string]any{"prompt_tokens": 100, "completion_tokens": 10}}
			return shpStep{handler: func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				json.NewEncoder(w).Encode(body)
			}}
		},
		auto: "auto",
		forced: func(tool string) any {
			return map[string]any{"type": "function", "function": map[string]any{"name": tool}}
		},
	}
	// anthropicWire is the adaptive-thinking Messages route: it cannot force a tool.
	anthropicWire = &forceWire{
		name: "anthropic", provider: "anthropic",
		configure: func(f *shpFx) {
			f.t.Helper()
			f.write(".kogen/project.yaml", f.read(".kogen/project.yaml")+"models:\n  shape: {provider: anthropic, model: claude-sonnet-5-5, effort: high}\n")
			f.git("add", ".kogen/project.yaml")
			f.git("commit", "-qm", "anthropic shape role")
			key, _ := json.Marshal(map[string]any{"provider": "anthropic", "api_key": "sk-ant-FIXTURE-KEY"})
			if err := os.WriteFile(filepath.Join(f.Home, ".kogen", "credentials", "anthropic.json"), key, 0o600); err != nil {
				f.t.Fatal(err)
			}
		},
		answer: func(text string, calls ...map[string]any) shpStep {
			event := func(kind string, kv map[string]any) map[string]any {
				kv["type"] = kind
				return kv
			}
			events := []map[string]any{event("message_start", map[string]any{"message": map[string]any{"id": "msg_fixture", "model": "claude-sonnet-5-5",
				"usage": map[string]any{"input_tokens": 10, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0}}})}
			block := func(b map[string]any) {
				i := len(events) / 2
				events = append(events, event("content_block_start", map[string]any{"index": i, "content_block": b}), event("content_block_stop", map[string]any{"index": i}))
			}
			if text != "" {
				block(map[string]any{"type": "text", "text": text})
			}
			stop := "end_turn"
			for _, c := range calls {
				stop = "tool_use"
				var input map[string]any
				json.Unmarshal([]byte(c["arguments"].(string)), &input)
				block(map[string]any{"type": "tool_use", "id": c["call_id"], "name": c["name"], "input": input})
			}
			events = append(events, event("message_delta", map[string]any{"delta": map[string]any{"stop_reason": stop}, "usage": map[string]any{"output_tokens": 12}}), event("message_stop", map[string]any{}))
			return shpStep{handler: func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "text/event-stream")
				for _, e := range events {
					b, _ := json.Marshal(e)
					fmt.Fprintf(w, "event: %s\ndata: %s\n\n", e["type"], b)
				}
			}}
		},
		auto:   map[string]any{"type": "auto"},
		forced: func(tool string) any { return map[string]any{"type": "tool", "name": tool} },
	}
)

// prose is an answer without any tool call; calls is an answer of these calls only.
func (w *forceWire) prose(text string) shpStep { return w.answer(text) }

func (w *forceWire) calls(calls ...map[string]any) shpStep { return w.answer("", calls...) }

// readReadme is the discovery step of a conversation.
func (w *forceWire) readReadme(id string) shpStep {
	return w.calls(shpCall(id, "read_file", map[string]any{"path": "README.md"}))
}

// shapeSubmit is a Shape submission that has inspected the repository in the same answer.
func (w *forceWire) shapeSubmit(id string, args any) shpStep {
	if m, ok := args.(map[string]any); ok {
		if _, files := m["files"]; files {
			return w.calls(shpCall(id+"-inspect", "read_file", map[string]any{"path": "README.md"}), shpCall(id, "submit", args))
		}
	}
	return w.calls(shpCall(id, "submit", args))
}

func (w *forceWire) shapeAck(id string) shpStep {
	return w.shapeSubmit(id, map[string]any{"files": []any{map[string]any{"path": ".kogen/intents/is-even/acceptance.feature", "content": shpFeature}}})
}

func (w *forceWire) refineSubmit(id string, pairs ...string) shpStep {
	var files []any
	for i := 0; i < len(pairs); i += 2 {
		files = append(files, map[string]any{"path": pairs[i], "content": pairs[i+1]})
	}
	return w.calls(shpCall(id, "submit_refinement", map[string]any{"files": files}))
}

// newShape is a Shape fixture speaking this wire.
func (w *forceWire) newShape(t *testing.T, steps ...shpStep) *shpFx {
	t.Helper()
	f := newShpFx(t, steps...)
	w.configure(f)
	return f
}

// newRefine is a Refine fixture of a ready draft whose shape role speaks this wire.
func (w *forceWire) newRefine(t *testing.T, steps ...shpStep) *refFx {
	t.Helper()
	return newRefFx(t, refOpts{wire: w}, steps...)
}

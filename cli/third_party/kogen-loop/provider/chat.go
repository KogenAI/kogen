package provider

import (
	"regexp"
	"unicode"
	"unicode/utf8"
)

// OpenCode Go speaks non-streaming Chat Completions at /inference/go/openai/v1/chat/completions
// (an OpenAI-compatible host at <base_url>/chat/completions):
// one JSON POST, one JSON answer. The complete received assistant message is kept (its
// reasoning included) as opencode_go_message and replayed exactly once; the normalized text
// and function calls only drive the tool loops.

const chatPath = "/inference/go/openai/v1/chat/completions"

func renderChat(info Info, req Request, id string, input []any) (rendered, error) {
	if hasImage(input) {
		return rendered{}, imageRefusal(info)
	}
	messages := append([]any{map[string]any{"role": "system", "content": req.Instructions}}, chatMessages(input)...)
	body := map[string]any{"model": req.Role.Model, "stream": false, "store": false, "messages": messages}
	if len(req.Tools) > 0 {
		tools := make([]any, len(req.Tools))
		for i, t := range req.Tools {
			fn := map[string]any{}
			if m, ok := asMap(t); ok {
				for k, v := range m {
					if k != "type" {
						fn[k] = v
					}
				}
			}
			tools[i] = map[string]any{"type": "function", "function": fn}
		}
		body["tool_choice"] = "auto"
		body["tools"] = tools
	}
	if req.Role.Effort != "default" {
		body["reasoning_effort"] = req.Role.Effort
	}
	if info.compatible() {
		// A generic host gets no vendor routing field or header (strict hosts refuse unknown
		// fields); its prefix cache still sees the frozen front and append-only history.
		return rendered{body: body, mode: "implicit"}, nil
	}
	return rendered{body: body, headers: map[string]string{"x-opencode-session": id}, mode: "implicit"}, nil
}

// chatMessages renders the conversation: a received assistant message goes back as it came
// (its normalized calls suppressed), each tool output becomes one role-tool message, user,
// system and assistant text keep their blocks as text blocks.
func chatMessages(input []any) []any {
	var out []any
	suppressed := map[string]bool{}
	for _, it := range input {
		item, ok := asMap(it)
		if !ok {
			continue
		}
		switch {
		case isObject(item["opencode_go_message"]):
			raw, _ := asMap(item["opencode_go_message"])
			out = append(out, raw)
			if calls, ok := asList(raw["tool_calls"]); ok {
				for _, c := range calls {
					if cm, ok := asMap(c); ok {
						if id, ok := cm["id"].(string); ok {
							suppressed[id] = true
						}
					}
				}
			}
		case item["type"] == "function_call" && suppressedCall(suppressed, item["call_id"]):
		case item["type"] == "function_call_output":
			out = append(out, map[string]any{"role": "tool", "tool_call_id": item["call_id"], "content": blockText(item["output"])})
		case item["role"] == "user" || item["role"] == "system" || item["role"] == "assistant":
			out = append(out, map[string]any{"role": item["role"], "content": blockText(item["content"])})
		}
	}
	return out
}

func suppressedCall(set map[string]bool, id any) bool {
	s, ok := id.(string)
	return ok && set[s]
}

var safeCodeRe = regexp.MustCompile(`^[a-zA-Z0-9_.:-]{1,128}$`)

// safeCode is a provider error code or type that is safe to report: 1..128 characters of
// letters, digits and _ . : -; anything else is dropped.
func safeCode(v any) any {
	if s, ok := v.(string); ok && safeCodeRe.MatchString(s) {
		return s
	}
	return nil
}

// validName is a nonempty value without control characters (a tool call's id or name).
func validName(v any) bool {
	s, ok := v.(string)
	if !ok || s == "" || !utf8.ValidString(s) {
		return false
	}
	for _, r := range s {
		if unicode.IsControl(r) {
			return false
		}
	}
	return true
}

// count is a reported token count: a nonnegative integer, else unknown.
func count(v any) *int {
	if n, ok := asInt(v); ok && n >= 0 {
		i := int(n)
		return &i
	}
	return nil
}

func detailCount(u map[string]any, key, field string) *int {
	if d, ok := asMap(u[key]); ok {
		return count(d[field])
	}
	return nil
}

func firstCount(counts ...*int) *int {
	for _, c := range counts {
		if c != nil {
			return c
		}
	}
	return nil
}

// toUsage is the compatible total of a validated usage: unknown counts are zero, and an
// inconsistent usage is not totalled.
func toUsage(k KnownUsage, state string) Usage {
	if state == UsageInconsistent {
		return Usage{}
	}
	n := func(p *int) int {
		if p == nil {
			return 0
		}
		return *p
	}
	return Usage{Input: n(k.Input), Cached: n(k.Cached), Output: n(k.Output), Reasoning: n(k.Reasoning)}
}

// adaptChat turns a Chat Completions answer into validated items: a complete assistant
// message that finished with stop or tool_calls, its calls each valid, unique and carrying a
// JSON object, and some text or call to act on. Anything else is unreadable, never
// partially executed.
func adaptChat(info Info, response map[string]any) result {
	invalid := result{kind: resInvalid, detail: "incomplete or malformed " + info.Label + " completion"}
	if response["error"] != nil {
		return invalid
	}
	if u, has := response["usage"]; has && u != nil {
		if _, ok := asMap(u); !ok {
			return invalid
		}
	}
	choices, ok := asList(response["choices"])
	if !ok || len(choices) == 0 {
		return invalid
	}
	choice, ok := asMap(choices[0])
	if !ok {
		return invalid
	}
	raw, ok := asMap(choice["message"])
	finish, hasFinish := choice["finish_reason"]
	if !ok || !hasFinish || raw["role"] != "assistant" {
		return invalid
	}
	content, hasContent := raw["content"]
	if !hasContent {
		return invalid
	}
	if content != nil {
		if _, ok := content.(string); !ok {
			return invalid
		}
	}
	if refusal := raw["refusal"]; refusal != nil && refusal != "" {
		return invalid
	}
	if finish != "stop" && finish != "tool_calls" {
		return invalid
	}
	var calls []any
	if tc := raw["tool_calls"]; tc != nil {
		list, ok := asList(tc)
		if !ok {
			return invalid
		}
		calls = list
	}
	if finish == "tool_calls" && len(calls) == 0 {
		return invalid
	}
	seen := map[string]bool{}
	for _, c := range calls {
		cm, ok := asMap(c)
		if !ok || !validCall(cm) {
			return invalid
		}
		id := cm["id"].(string)
		if seen[id] {
			return invalid
		}
		seen[id] = true
	}
	text, isText := raw["content"].(string)
	if len(calls) == 0 && (!isText || text == "") {
		return invalid
	}
	var texts []any
	if isText {
		texts = []any{map[string]any{"type": "output_text", "text": text}}
	}
	items := []map[string]any{{"type": "message", "role": "assistant", "content": nonNilList(texts), "opencode_go_message": raw}}
	for _, c := range calls {
		cm, _ := asMap(c)
		fn, _ := asMap(cm["function"])
		items = append(items, map[string]any{"type": "function_call", "call_id": cm["id"], "name": fn["name"], "arguments": fn["arguments"]})
	}
	u, _ := asMap(response["usage"])
	known := KnownUsage{}
	if u != nil {
		known = KnownUsage{
			Input:  count(u["prompt_tokens"]),
			Cached: firstCount(detailCount(u, "prompt_tokens_details", "cached_tokens"), count(u["prompt_cache_hit_tokens"]), count(u["cached_tokens"])),
			Output: count(u["completion_tokens"]), Reasoning: detailCount(u, "completion_tokens_details", "reasoning_tokens"),
		}
	}
	state := known.State()
	meta := map[string]any{}
	for _, k := range []string{"id", "model"} {
		if v, has := response[k]; has {
			meta[k] = v
		}
	}
	return result{kind: resOK, items: items, usage: toUsage(known, state), known: known, state: state, meta: meta}
}

func nonNilList(l []any) []any {
	if l == nil {
		return []any{}
	}
	return l
}

func validCall(c map[string]any) bool {
	fn, ok := asMap(c["function"])
	if !ok || c["type"] != "function" || !validName(c["id"]) || !validName(fn["name"]) {
		return false
	}
	args, ok := fn["arguments"].(string)
	return ok && argumentsObject(args) == "yes"
}

package provider

import (
	"reflect"
	"regexp"
	"strings"
	"unicode"
)

// Anthropic speaks the streamed Messages API at /v1/messages with an API key. The complete
// received assistant message (thinking, redacted thinking, text, tool_use blocks with their
// signatures) is kept as anthropic_message and replayed exactly once, unchanged.

const (
	messagesPath     = "/v1/messages"
	anthropicVersion = "2026-10-21"
	maxTokens        = 128000
)

// ephemeral is the default five-minute cache breakpoint.
func ephemeral() map[string]any { return map[string]any{"type": "ephemeral"} }

func renderMessages(info Info, req Request, id string, input []any) (rendered, error) {
	if hasImage(input) {
		return rendered{}, imageRefusal(info)
	}
	messages := anthropicMessages(input)
	var boundaries []any
	body := map[string]any{
		"model":         req.Role.Model,
		"stream":        true,
		"max_tokens":    maxTokens,
		"thinking":      map[string]any{"type": "adaptive"},
		"output_config": map[string]any{"effort": req.Role.Effort},
	}
	if p := ResolveProfile(req.Role); p != nil {
		body["stream"] = p.Settings.Stream
		body["thinking"] = map[string]any{"type": p.Settings.Reasoning}
		body["max_tokens"] = p.Limits.Output
	}
	if len(req.Tools) > 0 {
		tools := make([]any, len(req.Tools))
		for i, t := range req.Tools {
			m, _ := asMap(t)
			tools[i] = map[string]any{"name": m["name"], "description": m["description"], "input_schema": m["parameters"]}
		}
		last := tools[len(tools)-1].(map[string]any)
		last["cache_control"] = ephemeral()
		boundaries = append(boundaries, "tools["+itoa(int64(len(tools)-1))+"]")
		choice := "auto"
		if p := ResolveProfile(req.Role); p != nil {
			choice = p.Settings.Tools
		}
		body["tool_choice"] = map[string]any{"type": choice}
		body["tools"] = tools
	}
	body["system"] = []any{map[string]any{"type": "text", "text": req.Instructions, "cache_control": ephemeral()}}
	boundaries = append(boundaries, "system[0]")
	if where, ok := markNewest(messages); ok {
		boundaries = append(boundaries, where)
	}
	body["messages"] = messages
	return rendered{body: body, mode: "explicit", boundaries: boundaries}, nil
}

// markNewest puts the rolling breakpoint on the last content block of the newest message
// (a string content becomes one text block); thinking blocks cannot carry one. The message
// is replaced by a copy: the caller's replay items are never modified.
func markNewest(messages []any) (string, bool) {
	if len(messages) == 0 {
		return "", false
	}
	i := len(messages) - 1
	msg, _ := asMap(messages[i])
	var blocks []any
	switch c := msg["content"].(type) {
	case string:
		blocks = []any{map[string]any{"type": "text", "text": c}}
	default:
		list, ok := asList(c)
		if !ok || len(list) == 0 {
			return "", false
		}
		blocks = append([]any(nil), list...)
	}
	j := len(blocks) - 1
	b, ok := asMap(blocks[j])
	if !ok || b["type"] == "thinking" || b["type"] == "redacted_thinking" {
		return "", false
	}
	nb := make(map[string]any, len(b)+1)
	for k, v := range b {
		nb[k] = v
	}
	nb["cache_control"] = ephemeral()
	blocks[j] = nb
	nm := make(map[string]any, len(msg))
	for k, v := range msg {
		nm[k] = v
	}
	nm["content"] = blocks
	messages[i] = nm
	return "messages[" + itoa(int64(i)) + "].content[" + itoa(int64(j)) + "]", true
}

// anthropicMessages renders the conversation: a received assistant message goes back as it
// came, parallel tool results gather in the one user message that follows it, user and
// assistant text keep their blocks as text blocks.
func anthropicMessages(input []any) []any {
	messages := []any{}
	ids := map[string]bool{}
	for _, it := range input {
		item, ok := asMap(it)
		if !ok {
			continue
		}
		switch {
		case isObject(item["anthropic_message"]):
			raw, _ := asMap(item["anthropic_message"])
			messages = append(messages, raw)
			if blocks, ok := asList(raw["content"]); ok {
				for _, b := range blocks {
					if bm, ok := asMap(b); ok && bm["type"] == "tool_use" {
						if id, ok := bm["id"].(string); ok {
							ids[id] = true
						}
					}
				}
			}
		case item["type"] == "function_call" && suppressedCall(ids, item["call_id"]):
		case item["type"] == "function_call_output":
			block := map[string]any{"type": "tool_result", "tool_use_id": item["call_id"], "content": blockText(item["output"])}
			if n := len(messages); n > 0 {
				last, _ := asMap(messages[n-1])
				blocks, ok := asList(last["content"])
				if last["role"] == "user" && ok && len(blocks) > 0 {
					if first, ok := asMap(blocks[0]); ok && first["type"] == "tool_result" {
						messages[n-1] = map[string]any{"role": "user", "content": append(append([]any(nil), blocks...), block)}
						continue
					}
				}
			}
			messages = append(messages, map[string]any{"role": "user", "content": []any{block}})
		case item["role"] == "user" || item["role"] == "assistant":
			messages = append(messages, map[string]any{"role": item["role"], "content": blockText(item["content"])})
		}
	}
	return messages
}

// ---- stream assembly ----

var messageEvents = map[string]bool{
	"message_start": true, "content_block_start": true, "content_block_delta": true,
	"content_block_stop": true, "message_delta": true, "message_stop": true, "error": true,
}

// sseFrame is one SSE frame of the Messages stream: ignored, an event or unreadable.
type sseFrame struct {
	event   map[string]any
	invalid bool
}

var identifierRe = regexp.MustCompile(`^[A-Za-z0-9_.:-]+$`)

func decodeFrame(text string) sseFrame {
	var name *string
	var data []string
	for _, line := range strings.Split(text, "\n") {
		if rest, ok := strings.CutPrefix(line, "event:"); ok && name == nil {
			n := strings.TrimFunc(rest, unicode.IsSpace)
			name = &n
		}
		if rest, ok := strings.CutPrefix(line, "data:"); ok {
			data = append(data, strings.TrimLeftFunc(rest, unicode.IsSpace))
		}
	}
	joined := strings.Join(data, "\n")
	switch {
	case name != nil && !messageEvents[*name]:
		return sseFrame{}
	case joined == "":
		return sseFrame{}
	}
	v, err := decodeJSON([]byte(joined))
	e, ok := asMap(v)
	if err != nil || !ok {
		return sseFrame{invalid: true}
	}
	typ, has := e["type"]
	if !has || (name != nil && typ != *name) {
		return sseFrame{invalid: true}
	}
	return sseFrame{event: e}
}

// frames splits the normalized stream into its complete frames: the text after the last
// blank line is an unfinished frame and does not count.
func frames(text string) []sseFrame {
	parts := strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n\n")
	out := make([]sseFrame, 0, len(parts))
	for _, p := range parts[:len(parts)-1] {
		out = append(out, decodeFrame(p))
	}
	return out
}

type messageState struct {
	started, done bool
	blocks        []map[string]any
	active        map[string]any
	fragments     string
	stop          any
	usage         map[string]any
	meta          map[string]any
}

type malformed struct{}

func (malformed) Error() string { return "malformed Anthropic completion" }

func (s *messageState) apply(e map[string]any) error {
	typ, _ := e["type"].(string)
	if typ == "error" {
		return malformed{}
	}
	if !messageEvents[typ] {
		return nil // pings and unknown informational events
	}
	if s.done {
		return malformed{}
	}
	switch typ {
	case "message_start":
		m, ok := asMap(e["message"])
		if s.started || !ok {
			return malformed{}
		}
		u, err := usageMap(m["usage"])
		if err != nil {
			return err
		}
		s.started, s.usage, s.meta = true, u, map[string]any{"id": m["id"], "model": m["model"]}
	case "content_block_start":
		i, okI := asInt(e["index"])
		b, okB := asMap(e["content_block"])
		if !s.started || s.active != nil || s.stop != nil || !okI || !okB || int(i) != len(s.blocks) {
			return malformed{}
		}
		s.active = copyMap(b)
		s.fragments = ""
	case "content_block_delta":
		i, okI := asInt(e["index"])
		d, okD := asMap(e["delta"])
		if s.active == nil || s.stop != nil || !okI || !okD || int(i) != len(s.blocks) {
			return malformed{}
		}
		return s.delta(d)
	case "content_block_stop":
		i, okI := asInt(e["index"])
		if s.active == nil || s.stop != nil || !okI || int(i) != len(s.blocks) {
			return malformed{}
		}
		b := s.active
		if b["type"] == "tool_use" && s.fragments != "" {
			v, err := decodeJSON([]byte(s.fragments))
			if err != nil {
				return malformed{}
			}
			b["input"] = v
		}
		s.blocks, s.active, s.fragments = append(s.blocks, b), nil, ""
	case "message_delta":
		d, ok := asMap(e["delta"])
		if !s.started || s.active != nil || !ok {
			return malformed{}
		}
		stop := s.stop
		if v := d["stop_reason"]; v != nil && v != false {
			stop = v
		}
		if s.stop != nil && !reflect.DeepEqual(stop, s.stop) {
			return malformed{}
		}
		u, err := usageMap(e["usage"])
		if err != nil {
			return err
		}
		s.stop = stop
		for k, v := range u {
			s.usage[k] = v
		}
	case "message_stop":
		if !s.started || s.active != nil || s.stop == nil {
			return malformed{}
		}
		s.done = true
	}
	return nil
}

func (s *messageState) delta(d map[string]any) error {
	b := s.active
	switch b["type"] {
	case "tool_use":
		if v, ok := d["partial_json"].(string); ok && d["type"] == "input_json_delta" {
			s.fragments += v
			return nil
		}
	case "text":
		if v, ok := d["text"].(string); ok && d["type"] == "text_delta" {
			if cur, ok := b["text"].(string); ok {
				b["text"] = cur + v
				return nil
			}
		}
	case "thinking":
		if d["type"] == "thinking_delta" {
			if v, ok := d["thinking"].(string); ok {
				if cur, ok := b["thinking"].(string); ok {
					b["thinking"] = cur + v
					return nil
				}
			}
		}
		if d["type"] == "signature_delta" {
			if v, ok := d["signature"].(string); ok {
				cur, has := b["signature"]
				if !has {
					b["signature"] = v
					return nil
				}
				if c, ok := cur.(string); ok {
					b["signature"] = c + v
					return nil
				}
			}
		}
	}
	return malformed{}
}

func usageMap(v any) (map[string]any, error) {
	if v == nil {
		return map[string]any{}, nil
	}
	if m, ok := asMap(v); ok {
		return copyMap(m), nil
	}
	return nil, malformed{}
}

func copyMap(m map[string]any) map[string]any {
	out := make(map[string]any, len(m))
	for k, v := range m {
		out[k] = v
	}
	return out
}

func blank(v any) bool {
	s, ok := v.(string)
	return !ok || strings.TrimFunc(s, unicode.IsSpace) == ""
}

// parseMessages judges a whole Messages stream: a cut stream is transient, an unreadable or
// unsuccessful one invalid, an exhausted context window a definite refusal; only a complete,
// valid end_turn with text or calls, or tool_use with calls, is an answer, and no call is exposed
// unless every block is valid.
func parseMessages(text string) result {
	invalid := result{kind: resInvalid, detail: "malformed Anthropic completion"}
	cut := result{kind: resTransient, detail: "Anthropic cut stream"}
	fs := frames(text)
	for _, f := range fs {
		if f.invalid {
			for _, g := range fs {
				if g.event != nil && g.event["type"] == "message_stop" {
					return invalid
				}
			}
			return cut
		}
	}
	s := &messageState{usage: map[string]any{}, meta: map[string]any{}}
	for _, f := range fs {
		if f.event == nil {
			continue
		}
		if err := s.apply(f.event); err != nil {
			return invalid
		}
	}
	switch {
	case !s.done:
		return cut
	case s.stop == "model_context_window_exceeded":
		return result{kind: resRefused, reason: "context_too_long", fail: failure{status: int64(200)}}
	}
	return s.result()
}

func (s *messageState) result() result {
	var calls []map[string]any
	var texts []any
	valid := true
	for _, b := range s.blocks {
		switch b["type"] {
		case "text":
			t, ok := b["text"].(string)
			valid = valid && ok
			if ok && !blank(t) {
				texts = append(texts, map[string]any{"type": "output_text", "text": t})
			}
		case "tool_use":
			calls = append(calls, b)
			input, hasInput := b["input"]
			_, isObj := asMap(input)
			valid = valid && hasInput && isObj && validName(b["id"]) && validName(b["name"]) && !blank(b["id"]) && !blank(b["name"])
		case "thinking":
			_, okT := b["thinking"].(string)
			sig, okS := b["signature"].(string)
			valid = valid && okT && okS && sig != ""
		case "redacted_thinking":
			_, ok := b["data"].(string)
			valid = valid && ok
		default:
			valid = false
		}
	}
	ok := (s.stop == "end_turn" && (len(texts) > 0 || len(calls) > 0)) || (s.stop == "tool_use" && len(calls) > 0)
	if !valid || !ok {
		return result{kind: resInvalid, detail: "non-success Anthropic completion"}
	}
	ids := map[string]bool{}
	for _, c := range calls {
		ids[c["id"].(string)] = true // every id is a valid string by now
	}
	if len(ids) != len(calls) {
		return result{kind: resInvalid, detail: "non-success Anthropic completion"}
	}
	content := make([]any, len(s.blocks))
	for i, b := range s.blocks {
		content[i] = b
	}
	items := []map[string]any{{
		"type": "message", "role": "assistant", "content": nonNilList(texts),
		"anthropic_message": map[string]any{"role": "assistant", "content": content},
	}}
	for _, c := range calls {
		items = append(items, map[string]any{"type": "function_call", "call_id": c["id"], "name": c["name"], "arguments": string(mustEncode(c["input"]))})
	}
	known, inconsistent := anthropicUsage(s.usage)
	state := known.State()
	if inconsistent {
		state = UsageInconsistent
	}
	s.meta["anthropic_stop_reason"] = s.stop
	s.meta["anthropic_end_turn_tool_use"] = s.stop == "end_turn" && len(calls) > 0
	return result{kind: resOK, items: items, usage: toUsage(known, state), known: known, state: state, meta: s.meta}
}

// anthropicUsage normalizes the cumulative usage: total input is input + cache creation +
// cache read when all three were reported, cached is the cache read, write the cache
// creation; reasoning and the 30m/12h lifetimes are not reported (null). inconsistent
// reports a count that was present but not a nonnegative integer.
func anthropicUsage(u map[string]any) (known KnownUsage, inconsistent bool) {
	for _, f := range []string{"input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens"} {
		if v := u[f]; v != nil && count(v) == nil {
			inconsistent = true
		}
	}
	i, r, w := count(u["input_tokens"]), count(u["cache_read_input_tokens"]), count(u["cache_creation_input_tokens"])
	known = KnownUsage{Cached: r, Write: w, Output: count(u["output_tokens"])}
	if i != nil && r != nil && w != nil {
		total := *i + *r + *w
		known.Input = &total
	}
	return known, inconsistent
}

// safeIdentifier is a response identifier that cannot carry the key: 1..256 characters of
// letters, digits and _ . : -, not containing the key.
func safeIdentifier(v any, key string) any {
	s, ok := v.(string)
	if !ok || strings.Contains(s, key) || !identifierRe.MatchString(s) {
		return nil
	}
	return identifierOrNil(s)
}

var errorTypes = map[string]bool{
	"invalid_request_error": true, "authentication_error": true, "billing_error": true, "permission_error": true,
	"not_found_error": true, "request_too_large": true, "rate_limit_error": true, "api_error": true, "overloaded_error": true,
}

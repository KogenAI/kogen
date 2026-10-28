package provider

// rendered is one request as the provider's adapter writes it: the JSON body, the headers
// that carry routing (besides authorization and content negotiation) and the cache evidence.
type rendered struct {
	body    map[string]any
	headers map[string]string
	// mode and boundaries describe the cache controls the request carries.
	mode       any
	boundaries []any
}

// render writes the request for the provider's wire: the frozen front (instructions, tools
// in the caller's order) and the caller's append-only input, with the conversation's cache
// identity placed where that provider reads it. Deterministic: the same request is always
// the same bytes (encodeJSON sorts object keys).
func render(info Info, req Request, id string, unsupported bool) (rendered, error) {
	input := req.Input
	if input == nil {
		input = []any{}
	}
	if p := ResolveProfile(req.Role); p != nil && p.Settings.Images == "unsupported" && hasImage(input) {
		return rendered{}, imageRefusal(info)
	}
	info.wire = effectiveWire(info, req.Role)
	if req.DisableParallelToolCalls && info.wire == wireChat {
		return rendered{}, providerFail("unsupported_capability", "parallel tool calls cannot be disabled on "+info.Label+" (Chat Completions route "+info.Name+"); leave DisableParallelToolCalls false")
	}
	if req.ToolChoice != "" && !toolChoiceSupported(info, req.Role) {
		return rendered{}, providerFail("unsupported_capability", "ToolChoice cannot force a tool on "+info.Label+" ("+wireLabel(info.wire)+" route "+info.Name+"): its thinking mode refuses a forced tool; leave ToolChoice empty")
	}
	switch info.wire {
	case wireChat:
		return renderChat(info, req, id, input)
	case wireMessages:
		return renderMessages(info, req, id, input)
	}
	body := map[string]any{
		"model":        req.Role.Model,
		"reasoning":    map[string]any{"effort": req.Role.Effort},
		"include":      []any{"reasoning.encrypted_content"},
		"instructions": req.Instructions,
		"input":        input,
		"stream":       true,
		"store":        false,
	}
	if p := ResolveProfile(req.Role); p != nil {
		body["stream"] = p.Settings.Stream
		if p.Settings.Reasoning == "encrypted" {
			body["include"] = []any{"reasoning.encrypted_content"}
		}
	}
	if len(req.Tools) > 0 {
		body["tools"] = req.Tools
		body["tool_choice"] = "auto"
		if p := ResolveProfile(req.Role); p != nil {
			body["tool_choice"] = p.Settings.Tools
		}
		if req.ToolChoice != "" {
			body["tool_choice"] = map[string]any{"type": "function", "name": req.ToolChoice}
		}
	}
	if req.DisableParallelToolCalls {
		body["parallel_tool_calls"] = false
	}
	r := rendered{body: body, mode: "implicit"}
	switch {
	case info.chatgpt():
		r.headers = map[string]string{"session_id": id, "conversation_id": id}
		if !unsupported {
			body["prompt_cache_key"] = id
		}
	case !unsupported:
		body["prompt_cache_key"] = id
	}
	return r, nil
}

// effectiveWire is the wire a request for the role is written in: the provider's, unless a
// profile overrides it.
func effectiveWire(info Info, role Role) wire {
	if p := ResolveProfile(role); p != nil {
		switch p.Settings.Wire {
		case "messages":
			return wireMessages
		case "responses":
			return wireResponses
		}
	}
	return info.wire
}

func wireLabel(w wire) string {
	switch w {
	case wireChat:
		return "Chat Completions"
	case wireMessages:
		return "Messages"
	}
	return "Responses"
}

// messagesThinking is the thinking type the Messages wire sends for the role.
func messagesThinking(role Role) string {
	if p := ResolveProfile(role); p != nil {
		return p.Settings.Reasoning
	}
	return "adaptive"
}

// toolChoiceSupported reports whether the effective wire can force a named tool. Messages
// refuses a forced tool while thinking is adaptive (or enabled), so it only qualifies with
// thinking disabled; no current profile does.
func toolChoiceSupported(info Info, role Role) bool {
	switch effectiveWire(info, role) {
	case wireResponses, wireChat:
		return true
	case wireMessages:
		return messagesThinking(role) == "disabled"
	}
	return false
}

// SupportsToolChoice reports whether Request.ToolChoice can name a required tool for the
// role's effective wire. Unknown providers and current Anthropic Messages profiles
// (adaptive thinking) report false; Render and Respond then refuse a nonempty ToolChoice.
func SupportsToolChoice(role Role) bool {
	info, ok := Lookup(role.Provider)
	return ok && toolChoiceSupported(info, role)
}

// hasImage reports whether a typed image is anywhere in the value.
func hasImage(v any) bool {
	switch x := v.(type) {
	case []any:
		for _, e := range x {
			if hasImage(e) {
				return true
			}
		}
	case []map[string]any:
		for _, e := range x {
			if hasImage(e) {
				return true
			}
		}
	case map[string]any:
		if x["type"] == "input_image" {
			return true
		}
		for _, e := range x {
			if hasImage(e) {
				return true
			}
		}
	}
	return false
}

func imageRefusal(info Info) error {
	why := "images are unqualified"
	if info.Name == "anthropic" {
		why = "images are unsupported"
	}
	return providerFail("unsupported_capability", info.Label+" "+why+"; use external image preparation and pixel-review handoff")
}

// blockText turns native content blocks into the {type:"text"} blocks of the chat and
// messages wires without touching their text; any other content passes as it is.
func blockText(v any) any {
	list, ok := asList(v)
	if !ok {
		return v
	}
	out := make([]any, len(list))
	for i, b := range list {
		var t any
		if m, ok := asMap(b); ok {
			t = m["text"]
		}
		out[i] = map[string]any{"type": "text", "text": t}
	}
	return out
}

// conversationField is the body field that grows by appending: the conversation itself.
func (p Info) conversationField() string {
	if p.wire == wireResponses {
		return "input"
	}
	return "messages"
}

// encodeBody is the request's bytes: JSON with object keys in byte order, except that the
// conversation comes last. The frozen front (instructions or system, tools, parameters)
// then precedes the append-only history, so a request is the previous request's bytes
// followed by the new items.
func encodeBody(info Info, body map[string]any) ([]byte, error) {
	last := info.conversationField()
	tail, has := body[last]
	if !has {
		return encodeJSON(body)
	}
	front := make(map[string]any, len(body)-1)
	for k, v := range body {
		if k != last {
			front[k] = v
		}
	}
	head, err := encodeJSON(front)
	if err != nil {
		return nil, err
	}
	conv, err := encodeJSON(tail)
	if err != nil {
		return nil, err
	}
	name, err := encodeJSON(last)
	if err != nil {
		return nil, err
	}
	out := make([]byte, 0, len(head)+len(name)+len(conv)+2)
	out = append(out, head[:len(head)-1]...)
	if len(front) > 0 {
		out = append(out, ',')
	}
	out = append(out, name...)
	out = append(out, ':')
	out = append(out, conv...)
	return append(out, '}'), nil
}

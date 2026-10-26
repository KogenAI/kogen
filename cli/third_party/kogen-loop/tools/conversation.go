package tools

// The bookkeeping of the request / tool-call loop. A model answers a request with items:
// reasoning, messages and function calls. Kogen replays the supported ones in the next
// request and answers every function call with exactly one function_call_output.

// ReplayItem is the item as the next request replays it: only the fields the provider
// accepts back, with the received values and nothing manufactured for absent fields; nil
// for an item that is not replayed (other types, messages without text or refusal).
func ReplayItem(item map[string]any) map[string]any {
	switch item["type"] {
	case "function_call":
		return take(item, "type", "id", "call_id", "name", "arguments", "status")
	case "reasoning":
		return take(item, "type", "id", "encrypted_content", "summary", "status")
	case "message":
		// Provider-owned assistant messages (Anthropic blocks with their signatures,
		// OpenCode Go messages) replay exactly as received.
		for _, key := range []string{"anthropic_message", "opencode_go_message"} {
			if _, ok := item[key]; ok {
				return item
			}
		}
		content, ok := item["content"].([]any)
		if !ok {
			return nil
		}
		var kept []any
		for _, c := range content {
			part, _ := c.(map[string]any)
			switch part["type"] {
			case "output_text":
				if text, ok := part["text"].(string); ok {
					kept = append(kept, map[string]any{"type": "output_text", "text": text})
				}
			case "refusal":
				if text, ok := part["refusal"].(string); ok {
					kept = append(kept, map[string]any{"type": "refusal", "refusal": text})
				}
			}
		}
		if len(kept) == 0 {
			return nil
		}
		m := take(item, "type", "id", "role", "phase", "status")
		m["content"] = kept
		return m
	}
	return nil
}

func take(item map[string]any, keys ...string) map[string]any {
	m := map[string]any{}
	for _, k := range keys {
		if v, ok := item[k]; ok {
			m[k] = v
		}
	}
	return m
}

// Replay is the replayed items of a response, in the order received.
func Replay(items []map[string]any) []any {
	var out []any
	for _, it := range items {
		if r := ReplayItem(it); r != nil {
			out = append(out, r)
		}
	}
	return out
}

// Call is a function_call item of a response.
type Call struct {
	// Item is the item as received.
	Item map[string]any
	// Name and Arguments are the tool name and its JSON argument text ("" when absent).
	Name, Arguments string
}

// Calls lists the function calls of a response, in the order received.
func Calls(items []map[string]any) []Call {
	var calls []Call
	for _, it := range items {
		if it["type"] != "function_call" {
			continue
		}
		name, _ := it["name"].(string)
		args, _ := it["arguments"].(string)
		calls = append(calls, Call{Item: it, Name: name, Arguments: args})
	}
	return calls
}

// CallID is the call_id the answer must carry (nil when the item has none).
func (c Call) CallID() any { return c.Item["call_id"] }

// Args decodes the arguments as a JSON object. Anything else (invalid JSON, a value that is
// not an object, no arguments) is the object {"__invalid__": true}, so a tool reports a
// missing argument instead of failing the conversation.
func (c Call) Args() map[string]any { return DecodeArguments(c.Arguments) }

// Output is the function_call_output that answers the call; result is the tool's text, its
// typed parts or an Output.
func (c Call) Output(result any) map[string]any { return OutputItem(c.CallID(), result) }

// DecodeArguments decodes tool-call arguments; see Call.Args.
func DecodeArguments(arguments string) map[string]any {
	v, err := decodeJSON([]byte(arguments))
	if m, ok := v.(map[string]any); err == nil && ok {
		return m
	}
	return map[string]any{"__invalid__": true}
}

// OutputItem is the function_call_output for callID.
func OutputItem(callID, result any) map[string]any {
	if o, ok := result.(Output); ok {
		result = o.Value()
	}
	return map[string]any{"type": "function_call_output", "call_id": callID, "output": result}
}

// Conversation is the input of a request: the user's messages, the replayed answers of the
// model and the outputs of its tool calls, in order.
type Conversation struct{ Input []any }

// Add appends messages, such as {"role": "user", "content": text}.
func (c *Conversation) Add(items ...any) { c.Input = append(c.Input, items...) }

// Receive appends the replayed items of a response and returns its function calls. Every
// call must then be answered with Answer before the next request.
func (c *Conversation) Receive(items []map[string]any) []Call {
	c.Input = append(c.Input, Replay(items)...)
	return Calls(items)
}

// Answer appends the function_call_output of call.
func (c *Conversation) Answer(call Call, result any) {
	c.Input = append(c.Input, call.Output(result))
}

// Unanswered lists the call_ids of function calls without a function_call_output. A request
// may be sent only when there are none.
func (c *Conversation) Unanswered() []string { return Unanswered(c.Input) }

// Unanswered lists, in order, the call_ids of the function calls in input that no
// function_call_output answers.
func Unanswered(input []any) []string {
	answered := map[string]bool{}
	for _, it := range input {
		if m, ok := it.(map[string]any); ok && m["type"] == "function_call_output" {
			if id, ok := m["call_id"].(string); ok {
				answered[id] = true
			}
		}
	}
	var open []string
	for _, it := range input {
		if m, ok := it.(map[string]any); ok && m["type"] == "function_call" {
			if id, _ := m["call_id"].(string); !answered[id] {
				open = append(open, id)
			}
		}
	}
	return open
}

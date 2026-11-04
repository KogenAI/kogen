package buildprogram

import (
	"encoding/json"
	"strings"

	"github.com/KogenAI/kogen-review/review"
)

// reviewRequests are the provider requests of the reviewer, in order.
func (f *fakeProvider) reviewRequests() []map[string]any {
	var out []map[string]any
	for _, req := range f.requests() {
		if text := requestInstructions(req); text == review.ReviewerInstructions() {
			out = append(out, req)
		}
	}
	return out
}

// requestInstructions are the model's instructions: the request's own, or, for a model with
// prompt-cache support, the developer message that opens the input.
func requestInstructions(req map[string]any) string {
	if s, ok := req["instructions"].(string); ok {
		return s
	}
	items, _ := req["input"].([]any)
	if len(items) == 0 {
		return ""
	}
	dev, _ := items[0].(map[string]any)
	blocks, _ := dev["content"].([]any)
	if len(blocks) == 0 {
		return ""
	}
	text, _ := blocks[0].(map[string]any)["text"].(string)
	return text
}

// requestInput is the conversation of a request, without the developer message.
func requestInput(req map[string]any) []any {
	items, _ := req["input"].([]any)
	if _, ok := req["instructions"]; !ok && len(items) > 0 {
		return items[1:]
	}
	return items
}

func requestText(req map[string]any) string {
	b, _ := json.Marshal(requestInput(req))
	return string(b)
}

func submit(f *fakeProvider, verdict string, findings ...map[string]any) handler {
	list := []any{}
	for _, x := range findings {
		list = append(list, x)
	}
	return f.calls("submit_review", map[string]any{"verdict": verdict, "findings": list})
}

func finding(severity, message string) map[string]any {
	return map[string]any{"path": "app.txt", "line": 1, "severity": severity, "message": message}
}

func bigFile() string { return strings.Repeat("0123456789abcdef-line\n", 14_000) }

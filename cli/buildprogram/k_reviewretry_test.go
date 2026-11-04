package buildprogram

import (
	"encoding/json"
)

func prose(text string) handler {
	return sse(map[string]any{"type": "message", "id": "msg-1", "role": "assistant", "content": []any{map[string]any{"type": "output_text", "text": text}}})
}

func jsonOf(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}

func cacheKey(req map[string]any) string { k, _ := req["prompt_cache_key"].(string); return k }

var forcedSubmit = map[string]any{"type": "function", "name": "submit_review"}

func repeatHandler(h handler, n int) []handler {
	out := make([]handler, n)
	for i := range out {
		out[i] = h
	}
	return out
}

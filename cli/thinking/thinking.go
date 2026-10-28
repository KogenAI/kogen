// Package thinking removes stale thinking blocks from kept provider-owned messages.
package thinking

import "maps"

// Strip returns the items with every thinking and redacted_thinking block removed
// from provider-owned anthropic_message items: their signatures are bound to the conversation
// prefix they were produced in, which a reset changes. Other blocks and items stay as they are;
// a message left without blocks loses anthropic_message and renders from its plain content.
// The items passed in are not mutated.
func Strip(items []any) []any {
	out := make([]any, len(items))
	for i, it := range items {
		out[i] = it
		m, _ := it.(map[string]any)
		am, ok := m["anthropic_message"].(map[string]any)
		if !ok {
			continue
		}
		blocks, _ := am["content"].([]any)
		kept := []any{}
		for _, bl := range blocks {
			if bm, _ := bl.(map[string]any); bm["type"] == "thinking" || bm["type"] == "redacted_thinking" {
				continue
			}
			kept = append(kept, bl)
		}
		item := maps.Clone(m)
		if len(kept) == 0 {
			delete(item, "anthropic_message")
		} else {
			msg := maps.Clone(am)
			msg["content"] = kept
			item["anthropic_message"] = msg
		}
		out[i] = item
	}
	return out
}

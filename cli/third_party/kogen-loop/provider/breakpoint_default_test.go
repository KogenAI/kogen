package provider

import (
	"context"
	"strings"
	"testing"
)

// Every Messages breakpoint is the default five-minute {"type":"ephemeral"} with no ttl.
func TestMessagesBreakpointsAreTheDefaultFiveMinutes(t *testing.T) {
	e, f := keyEnv(t, "anthropic", claudeText("ok"))
	obs := &observer{}
	req := Request{Role: claudeRole, Instructions: "policy", Input: user("hi"), Tools: []any{goTool("read_file")}, CacheID: "fixed-cache-id"}
	if _, err := e.c.Respond(context.Background(), e.s, req, obs); err != nil {
		t.Fatal(err)
	}
	r := f.requests()
	if len(r) != 1 {
		t.Fatalf("requests = %d", len(r))
	}
	if got := string(r[0].Body); got != baselineBodies["anthropic"] {
		t.Errorf("default body changed\n got %s\nwant %s", got, baselineBodies["anthropic"])
	}
	if strings.Contains(string(r[0].Body), `"ttl"`) {
		t.Errorf("explicit ttl sent: %s", r[0].Body)
	}
	if r[0].Header.Get("Anthropic-Version") != "2026-10-21" || r[0].Header.Get("Anthropic-Beta") != "" {
		t.Errorf("headers = %v", r[0].Header)
	}
	recs := obs.records()
	if len(recs) != 1 {
		t.Fatalf("records = %d", len(recs))
	}
	cache, _ := recs[0]["cache"].(map[string]any)
	for _, key := range []string{"configured_ttl", "applied_ttl"} {
		if v, ok := cache[key]; !ok || v != nil {
			t.Errorf("%s = %v (present %v)", key, v, ok)
		}
	}
}

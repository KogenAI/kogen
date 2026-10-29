package provider

import (
	"context"
	"reflect"
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
	if got := string(r[0].Body); got != parallelBaseline["anthropic"] {
		t.Errorf("default body changed\n got %s\nwant %s", got, parallelBaseline["anthropic"])
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

// The optional authority marker is one more default breakpoint; the input is not modified.
func TestMessagesAuthorityBreakpointIsTheDefaultFiveMinutes(t *testing.T) {
	e, f := keyEnv(t, "anthropic", claudeText("ok"))
	input := append(twoBlockUser(), map[string]any{"role": "user", "content": "later"})
	before := jsonOf(t, input)
	if _, err := e.c.Respond(context.Background(), e.s, authorityRequest(input, intp(0)), nil); err != nil {
		t.Fatal(err)
	}
	r := f.requests()
	if len(r) != 1 {
		t.Fatalf("requests = %d", len(r))
	}
	want := []string{"tools[0]", "system[0]", "messages[0].content[0]", "messages[1].content[0]"}
	if got := markedAt(r[0].JSON); !reflect.DeepEqual(got, want) {
		t.Fatalf("markers = %v\n%s", got, r[0].Body)
	}
	if n := strings.Count(string(r[0].Body), `"cache_control":{"type":"ephemeral"}`); n != 4 || strings.Contains(string(r[0].Body), `"ttl"`) {
		t.Errorf("markers not all default: %s", r[0].Body)
	}
	if jsonOf(t, input) != before {
		t.Error("caller input mutated")
	}
}

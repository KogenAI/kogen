package provider

import (
	"context"
	"reflect"
	"strings"
	"testing"
)

func intp(i int) *int { return &i }

func twoBlockUser() []any {
	return []any{map[string]any{"role": "user", "content": []any{
		map[string]any{"type": "input_text", "text": "authority"},
		map[string]any{"type": "input_text", "text": "evidence"},
	}}}
}

func authorityRequest(input []any, boundary *int) Request {
	return Request{Role: claudeRole, Instructions: "policy", Input: input, Tools: []any{goTool("read_file")}, CacheID: "fixed-cache-id", AuthorityBoundary: boundary}
}

// markedAt lists the cache_control locations of a decoded Messages body.
func markedAt(body map[string]any) []string {
	var out []string
	for _, field := range []string{"tools", "system", "messages"} {
		list, _ := asList(body[field])
		for i, item := range list {
			m, _ := asMap(item)
			if field != "messages" {
				if m["cache_control"] != nil {
					out = append(out, field+"["+itoa(int64(i))+"]")
				}
				continue
			}
			blocks, _ := asList(m["content"])
			for j, b := range blocks {
				if bm, _ := asMap(b); bm["cache_control"] != nil {
					out = append(out, "messages["+itoa(int64(i))+"].content["+itoa(int64(j))+"]")
				}
			}
		}
	}
	return out
}

func TestAuthorityBreakpointDefault(t *testing.T) {
	// A nil boundary renders exactly the existing goldens on every route.
	for _, c := range parallelRoles {
		if got := parallelBody(t, c.role, false, true); got != parallelBaseline[c.name] {
			t.Errorf("%s: default body changed\n got %s\nwant %s", c.name, got, parallelBaseline[c.name])
		}
	}
	c := NewClient("")
	a, err := c.Render(authorityRequest(twoBlockUser(), nil))
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"tools[0]", "system[0]", "messages[0].content[1]"}; !reflect.DeepEqual(markedAt(a), want) {
		t.Errorf("default markers = %v", markedAt(a))
	}
}

func TestAuthorityBreakpointEnabled(t *testing.T) {
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
	if strings.Count(string(r[0].Body), `"cache_control":{"type":"ephemeral"}`) != 4 || strings.Contains(string(r[0].Body), "ttl") {
		t.Errorf("markers differ in TTL policy: %s", r[0].Body)
	}
	msgs := r[0].JSON["messages"].([]any)
	blocks := msgs[0].(map[string]any)["content"].([]any)
	if blocks[0].(map[string]any)["text"] != "authority" || blocks[1].(map[string]any)["text"] != "evidence" || blocks[1].(map[string]any)["cache_control"] != nil {
		t.Errorf("authority/evidence blocks: %v", blocks)
	}
	if jsonOf(t, input) != before {
		t.Error("caller input mutated")
	}
}

func TestAuthorityBreakpointBoundaries(t *testing.T) {
	c := NewClient("")
	input := twoBlockUser()
	before := jsonOf(t, input)
	for i, want := range [][]string{{"tools[0]", "system[0]", "messages[0].content[0]", "messages[0].content[1]"}, {"tools[0]", "system[0]", "messages[0].content[1]"}} {
		body, err := c.Render(authorityRequest(input, intp(i)))
		if err != nil {
			t.Fatal(err)
		}
		if got := markedAt(body); !reflect.DeepEqual(got, want) {
			t.Errorf("index %d markers = %v", i, got)
		}
	}
	body, err := c.Render(authorityRequest([]any{map[string]any{"role": "user", "content": "plain"}}, intp(0)))
	if err != nil {
		t.Fatal(err)
	}
	if got := markedAt(body); len(got) != 3 {
		t.Errorf("string content markers = %v", got)
	}
	if jsonOf(t, input) != before {
		t.Error("caller input mutated")
	}
	assistant := []any{map[string]any{"role": "assistant", "content": "x"}}
	cases := []struct {
		name  string
		input []any
		index int
	}{
		{"negative", input, -1},
		{"out of range", input, 2},
		{"string out of range", []any{map[string]any{"role": "user", "content": "plain"}}, 1},
		{"no user", assistant, 0},
		{"empty input", nil, 0},
		{"ordinary non-text", []any{map[string]any{"role": "user", "content": []any{map[string]any{"type": "tool_result", "content": "r"}}}}, 0},
		{"non-text", []any{map[string]any{"anthropic_message": map[string]any{"role": "user", "content": []any{map[string]any{"type": "tool_result", "tool_use_id": "x", "content": "r"}}}}}, 0},
	}
	for _, tc := range cases {
		e, f := keyEnv(t, "anthropic", claudeText("ok"))
		_, err := e.c.Respond(context.Background(), e.s, authorityRequest(tc.input, intp(tc.index)), nil)
		if err == nil || !strings.Contains(err.Error(), "invalid authority boundary") {
			t.Errorf("%s: err = %v", tc.name, err)
		}
		if n := len(f.requests()); n != 0 {
			t.Errorf("%s: %d requests sent", tc.name, n)
		}
	}
}

func rawUser(marks ...bool) []any {
	blocks := make([]any, len(marks))
	for i, m := range marks {
		b := map[string]any{"type": "text", "text": "block" + itoa(int64(i))}
		if m {
			b["cache_control"] = ephemeral()
		}
		blocks[i] = b
	}
	return []any{map[string]any{"anthropic_message": map[string]any{"role": "user", "content": blocks}}}
}

func TestAuthorityBreakpointLimit(t *testing.T) {
	c := NewClient("")
	later := map[string]any{"role": "user", "content": "newest"}
	// Three existing distinct locations (tools, system, retained block 1) plus authority is four.
	thinking := map[string]any{"anthropic_message": map[string]any{"role": "assistant", "content": []any{map[string]any{"type": "thinking", "thinking": "t", "signature": "s"}}}}
	body, err := c.Render(authorityRequest(append(rawUser(false, true), thinking), intp(0)))
	if err != nil {
		t.Fatal(err)
	}
	if got := markedAt(body); len(got) != 4 {
		t.Errorf("markers = %v", got)
	}
	// Four existing (tools, system, one retained, newest) plus a distinct authority is refused.
	e, f := keyEnv(t, "anthropic", claudeText("ok"))
	over := append(rawUser(false, true), later)
	_, err = e.c.Respond(context.Background(), e.s, authorityRequest(over, intp(0)), nil)
	if err == nil || !strings.Contains(err.Error(), "cache breakpoint limit exceeded") || len(f.requests()) != 0 {
		t.Fatalf("err = %v, requests = %d", err, len(f.requests()))
	}
	// Existing raw cache controls are retained on both the target and newest block.
	marked := rawUser(true, true)
	blocks := marked[0].(map[string]any)["anthropic_message"].(map[string]any)["content"].([]any)
	for _, block := range blocks {
		block.(map[string]any)["cache_control"] = map[string]any{"type": "ephemeral", "ttl": "1h"}
	}
	body, err = c.Render(authorityRequest(marked, intp(0)))
	if err != nil {
		t.Fatal(err)
	}
	msgs := body["messages"].([]any)
	out := msgs[0].(map[string]any)["content"].([]any)
	for _, block := range out {
		if block.(map[string]any)["cache_control"].(map[string]any)["ttl"] != "1h" {
			t.Error("raw marker changed")
		}
	}
	// Four existing locations (tools, system, retained block 0, newest); the target is the
	// retained block, so it is not counted twice and the request still renders.
	body, err = c.Render(authorityRequest(append(rawUser(true, false), later), intp(0)))
	if err != nil {
		t.Fatal(err)
	}
	if got := markedAt(body); len(got) != 4 {
		t.Errorf("idempotent markers = %v", got)
	}
}

func TestAuthorityBreakpointOtherRoutes(t *testing.T) {
	for _, c := range parallelRoles {
		if c.info == "anthropic" {
			continue
		}
		info, _ := Lookup(c.role.Provider)
		render := func(b *int) string {
			req := Request{Role: c.role, Instructions: "policy", Input: twoBlockUser(), Tools: []any{goTool("read_file")}, CacheID: "fixed-cache-id", AuthorityBoundary: b}
			body, err := NewClient("").Render(req)
			if err != nil {
				t.Fatal(err)
			}
			enc, err := encodeBody(info, body)
			if err != nil {
				t.Fatal(err)
			}
			return string(enc)
		}
		if render(nil) != render(intp(1)) || render(nil) != render(intp(99)) {
			t.Errorf("%s: enabled bytes differ", c.name)
		}
	}
}

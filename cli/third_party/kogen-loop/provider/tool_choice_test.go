package provider

import (
	"encoding/json"
	"fmt"
	"os"
	"reflect"
	"strings"
	"testing"
)

// decodeStd decodes a transport body into plain JSON values, which compare arrays in order
// and strings exactly.
func decodeStd(t *testing.T, label string, b []byte) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatalf("%s: %v in %s", label, err, b)
	}
	return m
}

func tcGolden(t *testing.T) map[string]string {
	t.Helper()
	data, err := os.ReadFile("testdata/tool_choice_empty_golden.json")
	if err != nil {
		t.Fatal(err)
	}
	var golden map[string]string
	if err := json.Unmarshal(data, &golden); err != nil {
		t.Fatal(err)
	}
	return golden
}

func tcKey(route string, tools, parallelOff bool) string {
	return fmt.Sprintf("%s/tools=%v/parallel_off=%v", route, tools, parallelOff)
}

// tcCases lists each route's combinations of tools and the existing parallel control; Chat
// Completions refuses the control, so it has none.
func tcCases(r tcRoute, f func(tools, parallelOff bool)) {
	for _, tools := range []bool{true, false} {
		for _, parallelOff := range []bool{false, true} {
			if parallelOff && r.wire == "chat" {
				continue
			}
			f(tools, parallelOff)
		}
	}
}

// Empty ToolChoice sends the bytes captured from the unchanged encoders (testdata was
// recorded before ToolChoice existed), including the existing automatic tool_choice.
func TestToolChoiceEmptyBytes(t *testing.T) {
	golden := tcGolden(t)
	for _, r := range tcRoutes {
		tcCases(r, func(tools, parallelOff bool) {
			key := tcKey(r.name, tools, parallelOff)
			want, ok := golden[key]
			if !ok {
				t.Fatalf("no golden for %s", key)
			}
			reqs, err := tcRespond(t, r, nil, tools, parallelOff)
			if err != nil || len(reqs) != 1 {
				t.Fatalf("%s: err=%v requests=%d", key, err, len(reqs))
			}
			if got := string(reqs[0].Body); got != want {
				t.Errorf("%s: bytes changed\n got %s\nwant %s", key, got, want)
			}
		})
	}
}

// A named choice changes only tool_choice, and only where the route can force it.
func TestToolChoiceTransport(t *testing.T) {
	golden := tcGolden(t)
	forced := map[string]func(name string) string{
		"responses": func(n string) string { return `{"type":"function","name":` + quote(n) + `}` },
		"chat":      func(n string) string { return `{"type":"function","function":{"name":` + quote(n) + `}}` },
	}
	if forced["responses"]("submit") != `{"type":"function","name":"submit"}` || forced["chat"]("submit") != `{"type":"function","function":{"name":"submit"}}` {
		t.Fatal("expected shapes drifted")
	}
	for _, r := range tcRoutes {
		shape, supported := forced[r.wire]
		if !supported {
			continue
		}
		for _, name := range []string{"submit", "read_file", "other-tool"} {
			tcCases(r, func(tools, parallelOff bool) {
				key := tcKey(r.name, tools, parallelOff) + "/" + name
				reqs, err := tcRespond(t, r, func(q *Request) { q.ToolChoice = name }, tools, parallelOff)
				if err != nil || len(reqs) != 1 {
					t.Fatalf("%s: err=%v requests=%d", key, err, len(reqs))
				}
				got := decodeStd(t, key, reqs[0].Body)
				want := decodeStd(t, key, []byte(golden[tcKey(r.name, tools, parallelOff)]))
				if tools {
					want["tool_choice"] = decodeStd(t, key, []byte(shape(name)))
					if !reflect.DeepEqual(got["tool_choice"], want["tool_choice"]) {
						t.Errorf("%s: tool_choice %v, want %s", key, got["tool_choice"], shape(name))
					}
				} else if _, has := got["tool_choice"]; has {
					t.Errorf("%s: tool_choice sent without tools: %s", key, reqs[0].Body)
				}
				if !reflect.DeepEqual(got, want) {
					t.Errorf("%s: more than tool_choice changed\n got %s\nwant %v", key, reqs[0].Body, want)
				}
				if parallelOff && r.wire == "responses" && got["parallel_tool_calls"] != false {
					t.Errorf("%s: parallel control lost: %s", key, reqs[0].Body)
				}
			})
		}
	}
}

func quote(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}

// Support agrees with the refusal: a route that reports false refuses before any transport,
// in Render and in Respond, never ignoring the choice.
func TestToolChoiceUnsupported(t *testing.T) {
	for _, r := range tcRoutes {
		e, role, requests := r.setup(t)
		want := r.wire != "messages"
		if got := SupportsToolChoice(role); got != want {
			t.Errorf("%s: SupportsToolChoice = %v, want %v", r.name, got, want)
		}
		if want {
			continue
		}
		for _, tools := range []bool{true, false} {
			for _, parallelOff := range []bool{false, true} {
				req := tcRequest(role, tools, parallelOff)
				req.ToolChoice = "submit"
				label := fmt.Sprintf("%s tools=%v parallel_off=%v", r.name, tools, parallelOff)
				check := func(what string, err error) {
					t.Helper()
					se := mustErr(t, err)
					if se.Class != "provider" || se.Reason != "unsupported_capability" || se.Exit != 4 ||
						!strings.Contains(se.Detail, "ToolChoice") || !strings.Contains(se.Detail, "Messages route anthropic") {
						t.Errorf("%s %s: %v", label, what, se)
					}
				}
				_, err := e.c.Render(req)
				check("Render", err)
				_, err = tcRespondWith(t, e, req)
				check("Respond", err)
			}
		}
		if n := len(requests()); n != 0 {
			t.Errorf("%s: %d transport attempts for a refused choice", r.name, n)
		}
		// Empty still reaches the route on the same client.
		if _, err := tcRespondWith(t, e, tcRequest(role, true, false)); err != nil || len(requests()) != 1 {
			t.Errorf("%s: empty choice: err=%v requests=%d", r.name, err, len(requests()))
		}
	}
	for _, role := range []Role{{Provider: "nonesuch", Model: "m", Effort: "e"}, {Provider: "Anthropic", Model: "claude-opus-5-5", Effort: "high"}} {
		if SupportsToolChoice(role) {
			t.Errorf("unknown provider %q reports support", role.Provider)
		}
		e, _, _ := tcRoutes[0].setup(t)
		req := tcRequest(role, true, false)
		req.ToolChoice = "submit"
		if _, err := e.c.Render(req); err == nil {
			t.Errorf("Render accepted unknown provider %q", role.Provider)
		}
		if _, err := tcRespondWith(t, e, req); err == nil {
			t.Errorf("Respond accepted unknown provider %q", role.Provider)
		}
	}
}

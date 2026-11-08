package provider

import (
	"reflect"
	"testing"
)

// Requiring progress must leave inspection and preparation tools selectable.
// Compare whole transport bodies so the requirement cannot drop tools or history.
func TestRequireAnyToolTransport(t *testing.T) {
	t.Parallel()
	golden := tcGolden(t)
	for _, r := range tcRoutes {
		if r.wire == "messages" {
			continue // these fixtures use adaptive thinking, which refuses forcing
		}
		for _, tools := range []bool{true, false} {
			reqs, err := tcRespond(t, r, func(q *Request) { q.RequireTool = true }, tools)
			if err != nil || len(reqs) != 1 {
				t.Fatalf("%s tools=%v: %v (%d requests)", r.name, tools, err, len(reqs))
			}
			got := decodeStd(t, r.name, reqs[0].Body)
			want := decodeStd(t, r.name, []byte(golden[tcKey(r.name, tools)]))
			if tools {
				want["tool_choice"] = "required"
			}
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("%s: got %v, want %v", r.name, got, want)
			}
		}
	}
}

func TestRequireAnyToolUnsupported(t *testing.T) {
	t.Parallel()
	for _, r := range tcRoutes {
		if r.wire != "messages" {
			continue
		}
		e, role, requests := r.setup(t)
		req := tcRequest(role, true)
		req.RequireTool = true
		if _, err := e.c.Render(req); err == nil {
			t.Fatalf("%s accepted unsupported forcing", r.name)
		}
		if _, err := tcRespondWith(t, e, req); err == nil || len(requests()) != 0 {
			t.Fatalf("%s: err=%v requests=%d", r.name, err, len(requests()))
		}
	}
}

func TestNamedToolTakesPrecedence(t *testing.T) {
	t.Parallel()
	for _, r := range tcRoutes {
		if r.wire == "messages" {
			continue
		}
		named, err := tcRespond(t, r, func(q *Request) { q.ToolChoice = "submit" }, true)
		if err != nil {
			t.Fatal(err)
		}
		both, err := tcRespond(t, r, func(q *Request) { q.ToolChoice = "submit"; q.RequireTool = true }, true)
		if err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(decodeStd(t, r.name, named[0].Body), decodeStd(t, r.name, both[0].Body)) {
			t.Fatalf("%s: requiring any tool overrode the named requirement", r.name)
		}
	}
}

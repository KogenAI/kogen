package provider

import (
	"bytes"
	"context"
	"strings"
	"testing"
)

func TestPrefixLogOffsets(t *testing.T) {
	for _, n := range []int{0, 10239, 10240, 10241} {
		a := []byte(strings.Repeat("a", n) + "x")
		b := []byte(strings.Repeat("a", n) + "y")
		status, off := prefixCompare(a, b)
		if status != "diverged" || off == nil || *off != n {
			t.Fatalf("%d: %s %v", n, status, off)
		}
	}
	for _, pair := range [][2]string{{"abc", "abcd"}, {"abcd", "abc"}, {"éx", "éy"}} {
		_, off := prefixCompare([]byte(pair[0]), []byte(pair[1]))
		want := 3
		if pair[0] == "éx" {
			want = 2
		}
		if off == nil || *off != want {
			t.Fatal(pair, off)
		}
	}
	status, off := prefixCompare([]byte("same"), []byte("same"))
	if status != "identical" || off != nil {
		t.Fatal(status, off)
	}
}

func prefixEnv(t *testing.T, c cachingCase, handlers ...handler) (*env, *keyFake) {
	t.Helper()
	e, f := keyEnv(t, c.role.Provider, handlers...)
	if c.name == "chatgpt" || c.name == "supergrok" {
		e = newEnvWithURL(t, f.srv.URL)
	}
	if c.prep != nil {
		c.prep(e)
	}
	return e, f
}
func checkEvents(t *testing.T, ev []PrefixEvent, reqs []recorded) {
	t.Helper()
	if len(ev) != len(reqs) {
		t.Fatalf("events %d requests %d", len(ev), len(reqs))
	}
	for i, e := range ev {
		if e.CurrentBytes != len(reqs[i].Body) {
			t.Fatal(e)
		}
		if i == 0 {
			if e.Status != "first" || e.Offset != nil || e.PreviousBytes != nil {
				t.Fatal(e)
			}
			continue
		}
		a, b := reqs[i-1].Body, reqs[i].Body
		n := 0
		for n < len(a) && n < len(b) && a[n] == b[n] {
			n++
		}
		if e.PreviousBytes == nil || *e.PreviousBytes != len(a) {
			t.Fatal(e)
		}
		if n == len(a) && n == len(b) {
			if e.Status != "identical" || e.Offset != nil {
				t.Fatal(e)
			}
		} else if e.Status != "diverged" || e.Offset == nil || *e.Offset != n {
			t.Fatal(e, n)
		}
	}
}
func TestPrefixLogAttempts(t *testing.T) {
	for _, c := range []cachingCase{cachingCases[0], cachingCases[2], cachingCases[3]} {
		t.Run(c.name, func(t *testing.T) {
			e, f := prefixEnv(t, c, jsonAnswer(503, map[string]any{}), c.answer(1), c.answer(2), c.answer(3))
			var ev []PrefixEvent
			e.c.PrefixLog = func(p PrefixEvent) { ev = append(ev, p) }
			req := Request{Role: c.role, CacheID: "fixed", Instructions: "markerXYZ", Input: []any{map[string]any{"role": "user", "content": "hello"}}}
			info, _ := Lookup(req.Role.Provider)
			body, _ := encodeBody(info, e.c.Body(req))
			pos := bytes.Index(body, []byte("markerXYZ"))
			if pos < 0 || pos >= 10240 {
				t.Fatal(pos)
			}
			req.Instructions = strings.Repeat("a", 10240-pos) + "x"
			for i := 0; i < 2; i++ {
				if _, err := e.c.Respond(context.Background(), e.s, req, nil); err != nil {
					t.Fatal(err)
				}
				req.Instructions = strings.Repeat("a", 10240-pos) + "y"
			}
			checkEvents(t, ev, f.requests())
			if len(ev) != 3 || ev[2].Offset == nil || *ev[2].Offset != 10240 {
				t.Fatal(ev)
			}
		})
	}
	c := cachingCases[0]
	e, f := prefixEnv(t, c, jsonAnswer(400, map[string]any{"error": map[string]any{"code": "unknown_parameter", "param": "prompt_cache_key", "message": "unsupported"}}), c.answer(1))
	var ev []PrefixEvent
	e.c.PrefixLog = func(p PrefixEvent) { ev = append(ev, p) }
	_, err := e.c.Respond(context.Background(), e.s, Request{Role: c.role, CacheID: "fixed"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	checkEvents(t, ev, f.requests())
	if len(ev) != 2 || ev[1].Status != "diverged" {
		t.Fatal(ev)
	}
}
func TestPrefixLogOff(t *testing.T) {
	c := cachingCases[0]
	e, f := prefixEnv(t, c, c.answer(1), c.answer(2))
	req := Request{Role: c.role, CacheID: "fixed"}
	if _, err := e.c.Respond(context.Background(), e.s, req, nil); err != nil {
		t.Fatal(err)
	}
	if e.c.prefixBodies != nil {
		t.Fatal("off retained state")
	}
	var ev []PrefixEvent
	e.c.PrefixLog = func(p PrefixEvent) { ev = append(ev, p) }
	if _, err := e.c.Respond(context.Background(), e.s, req, nil); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(f.requests()[0].Body, f.requests()[1].Body) || len(ev) != 1 || ev[0].Status != "first" {
		t.Fatal(ev)
	}
	r := &run{k: &call{c: &Client{}}}
	if n := testing.AllocsPerRun(100, func() { r.logPrefix() }); n != 0 {
		t.Fatal(n)
	}
}
func TestPrefixLogLifetime(t *testing.T) {
	c := cachingCases[0]
	e, _ := prefixEnv(t, c, c.answer(1), c.answer(2), c.answer(3), c.answer(4), c.answer(5))
	var ev []PrefixEvent
	e.c.PrefixLog = func(p PrefixEvent) { ev = append(ev, p) }
	a := Request{Role: c.role, CacheID: "a"}
	b := Request{Role: c.role, Scope: "b"}
	for _, r := range []Request{a, b, a} {
		if _, err := e.c.Respond(context.Background(), e.s, r, nil); err != nil {
			t.Fatal(err)
		}
	}
	if ev[0].Status != "first" || ev[1].Status != "first" || ev[2].Status != "identical" {
		t.Fatal(ev)
	}
	e.c.EndPrefixLog(a)
	e.c.EndPrefixLog(b)
	if len(e.c.prefixBodies) != 0 {
		t.Fatal(e.c.prefixBodies)
	}
	for _, r := range []Request{a, b} {
		if _, err := e.c.Respond(context.Background(), e.s, r, nil); err != nil {
			t.Fatal(err)
		}
	}
	if ev[3].Status != "first" || ev[4].Status != "first" {
		t.Fatal(ev)
	}
	// A caller releases even when a subsequent call is cancelled.
	func() {
		defer e.c.EndPrefixLog(a)
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		if _, err := e.c.Respond(ctx, e.s, a, nil); err == nil {
			t.Fatal("expected cancellation")
		}
	}()
	if _, ok := e.c.prefixBodies["id:a"]; ok {
		t.Fatal("cancelled conversation retained")
	}

}
func TestPrefixLogMetadata(t *testing.T) {
	c := cachingCases[0]
	e, _ := prefixEnv(t, c, c.answer(1), c.answer(2))
	var ev []PrefixEvent
	e.c.PrefixLog = func(p PrefixEvent) { ev = append(ev, p) }
	req := Request{Role: c.role, CacheID: "fixed", Instructions: "private body", Context: map[string]any{"role": "build"}}
	e.c.Body(req)
	if _, err := e.c.Render(req); err != nil {
		t.Fatal(err)
	}
	if len(ev) != 0 {
		t.Fatal(ev)
	}
	if _, err := e.c.Respond(context.Background(), e.s, req, nil); err != nil {
		t.Fatal(err)
	}
	req.Context["role"] = "review"
	e.c.Body(req)
	if _, err := e.c.Respond(context.Background(), e.s, req, nil); err != nil {
		t.Fatal(err)
	}
	if ev[0].Context["role"] != "build" || ev[0].Role != req.Role || ev[1].Status != "identical" {
		t.Fatal(ev)
	}
}

func TestPrefixLogZeroClientIdentity(t *testing.T) {
	c := cachingCases[0]
	e, _ := prefixEnv(t, c, c.answer(1), c.answer(2), c.answer(3))
	e.c.Cache = nil
	var events []PrefixEvent
	e.c.PrefixLog = func(p PrefixEvent) { events = append(events, p) }
	req := Request{Role: c.role, Scope: "conversation"}
	for i := 0; i < 2; i++ {
		if _, err := e.c.Respond(context.Background(), e.s, req, nil); err != nil {
			t.Fatal(err)
		}
	}
	if events[0].ConversationID != events[1].ConversationID || events[1].Status == "first" {
		t.Fatal(events)
	}
	// An explicit ID equal to the fallback identifier remains a separate conversation.
	explicit := Request{Role: c.role, CacheID: events[0].ConversationID}
	if _, err := e.c.Respond(context.Background(), e.s, explicit, nil); err != nil {
		t.Fatal(err)
	}
	if events[2].Status != "first" {
		t.Fatal(events)
	}
	e.c.EndPrefixLog(req)
	if len(e.c.prefixBodies) != 1 {
		t.Fatal(e.c.prefixBodies)
	}
	e.c.EndPrefixLog(explicit)
	if len(e.c.prefixBodies) != 0 {
		t.Fatal(e.c.prefixBodies)
	}
}

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/KogenAI/kogen-loop/provider"
	"github.com/KogenAI/kogen-loop/sys"
)

// The vendored kogen-loop streams Chat Completions responses (kogen-loop@b05fcf4). These tests
// prove it from the CLI package: the request body asks for a stream, and a first byte that
// arrives 60 seconds late (simulated) is still waited for.

func TestVendoredChatRequestBodyAsksForAStream(t *testing.T) {
	src, err := os.ReadFile(filepath.Join("third_party", "kogen-loop", "provider", "chat.go"))
	if err != nil {
		t.Fatal(err)
	}
	flag := regexp.MustCompile(`"stream":\s*(true|false)`)
	var got []string
	for _, m := range flag.FindAllStringSubmatch(string(src), -1) {
		got = append(got, m[1])
	}
	if len(got) == 0 {
		t.Fatal(`vendored chat.go does not set "stream" in the Chat Completions request body`)
	}
	for _, v := range got {
		if v != "true" {
			t.Fatalf(`vendored chat.go sends "stream": %s; want "stream": true`, v)
		}
	}
}

// simClock is a clock whose time moves only when a test advances it.
type simClock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *simClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *simClock) Advance(d time.Duration) {
	c.mu.Lock()
	c.t = c.t.Add(d)
	c.mu.Unlock()
}

func (c *simClock) Sleep(ctx context.Context, d time.Duration) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	c.Advance(d)
	return nil
}

func TestVendoredChatClientWaitsSixtySimulatedSecondsForTheFirstByte(t *testing.T) {
	clk := &simClock{t: time.Date(2026, 11, 22, 12, 0, 0, 0, time.UTC)}
	var mu sync.Mutex
	var bodies []map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		mu.Lock()
		bodies = append(bodies, body)
		mu.Unlock()
		// The first byte is 60 s late on the simulated clock. The real-time hold lets the
		// attempt's watchdog (it polls about once a second) read that clock and apply its
		// header wait: a 45 s wait fires here, the vendored 120 s one does not.
		clk.Advance(60 * time.Second)
		select {
		case <-time.After(2500 * time.Millisecond):
		case <-r.Context().Done():
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		chunk := func(delta map[string]any, finish any, extra map[string]any) {
			choice := map[string]any{"index": 0, "delta": delta, "finish_reason": finish}
			ev := map[string]any{"id": "chatcmpl-slow", "object": "chat.completion.chunk", "model": "qwen3-coder:30b", "choices": []any{choice}}
			for k, v := range extra {
				ev[k] = v
			}
			raw, _ := json.Marshal(ev)
			fmt.Fprintf(w, "data: %s\n\n", raw)
			if f, ok := w.(http.Flusher); ok {
				f.Flush()
			}
		}
		chunk(map[string]any{"role": "assistant", "content": "slow "}, nil, nil)
		chunk(map[string]any{"content": "answer"}, nil, nil)
		chunk(map[string]any{}, "stop", map[string]any{"usage": map[string]any{"prompt_tokens": 10, "completion_tokens": 2}})
		fmt.Fprint(w, "data: [DONE]\n\n")
	}))
	defer srv.Close()

	home := t.TempDir()
	sess := sys.NewWith([]string{"HOME=" + home, "PATH=" + os.Getenv("PATH")}, home)
	client := &provider.Client{Now: clk.Now, Sleep: clk.Sleep, Cache: provider.NewCache(nil), Version: "kogen dev+12345678 (test)"}
	role := provider.Role{Provider: "openai-compatible", Model: "qwen3-coder:30b", Effort: "default", BaseURL: srv.URL + "/v1"}
	req := provider.Request{
		Role:         role,
		Instructions: "policy",
		Input:        []any{map[string]any{"role": "user", "content": []any{map[string]any{"type": "input_text", "text": "hi"}}}},
		Scope:        "chat-streaming",
	}
	resp, err := client.Respond(context.Background(), sess, req, nil)
	if err != nil {
		t.Fatalf("a first byte 60 s late must succeed: %v", err)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(bodies) != 1 {
		t.Fatalf("%d requests, want exactly 1", len(bodies))
	}
	if bodies[0]["stream"] != true {
		t.Fatalf(`request body "stream" = %v, want true`, bodies[0]["stream"])
	}
	if text := fmt.Sprint(resp.Items); !strings.Contains(text, "slow answer") {
		t.Fatalf("streamed answer not assembled: %s", text)
	}
}

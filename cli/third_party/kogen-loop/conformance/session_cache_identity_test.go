package conformance

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"kogen-loop/api"
	"kogen-loop/loop"
	"kogen-loop/provider"
)

var cacheProfiles = []provider.Role{
	{Provider: "chatgpt", Model: "fixture-model", Effort: "medium"},
	{Provider: "supergrok", Model: "grok-4.7", Effort: "low"},
	{Provider: "opencode-go", Model: "kimi-k3", Effort: "high"},
}

func cacheSetup(t *testing.T, role provider.Role, count int) (*fakeProvider, loop.SessionConfig) {
	t.Helper()
	w := newWorld(t).signIn()
	dir := filepath.Join(w.home, ".kogen", "credentials")
	creds := map[string]any{"client_id": "synthetic-client", "referrer": "kogen", "access_token": "synthetic-access", "refresh_token": "synthetic-refresh", "expires_at": time.Now().Unix() + 3600, "scope": "api:access"}
	if role.Provider == "opencode-go" {
		creds = map[string]any{"provider": "opencode-go", "api_key": "synthetic-key"}
	}
	if role.Provider != "chatgpt" {
		b, _ := json.Marshal(creds)
		if err := os.WriteFile(filepath.Join(dir, role.Provider+".json"), b, 0600); err != nil {
			t.Fatal(err)
		}
	}
	script := make([]exchange, count)
	for i := range script {
		script[i] = exchange{Items: []map[string]any{message("done")}}
	}
	f := newFakeProvider(t, script)
	var events []api.Event
	cfg := sessionConfig(w, f, &events)
	cfg.Role = role
	return f, cfg
}

func cacheRound(t *testing.T, s *loop.Session) {
	t.Helper()
	if _, err := s.Round(context.Background(), "hello"); err != nil {
		t.Fatal(err)
	}
}

func cacheCheck(t *testing.T, f *fakeProvider, i int, role provider.Role, key string) {
	t.Helper()
	b, h := f.bodies[i], f.headers[i]
	switch role.Provider {
	case "chatgpt":
		if b["prompt_cache_key"] != key || h.Get("session_id") != key || h.Get("conversation_id") != key {
			t.Fatalf("routing: %v %v", b, h)
		}
	case "supergrok":
		if b["prompt_cache_key"] != key || h.Get("session_id") != "" || h.Get("conversation_id") != "" {
			t.Fatalf("routing: %v %v", b, h)
		}
	case "opencode-go":
		if _, ok := b["prompt_cache_key"]; ok || h.Get("X-Opencode-Session") != key {
			t.Fatalf("routing: %v %v", b, h)
		}
	}
}

// The request a session sent is byte-identical to a direct provider request that uses the
// session ID as cache identity.
func cacheReference(t *testing.T, f *fakeProvider, cfg loop.SessionConfig, s *loop.Session, index int) {
	t.Helper()
	_, err := cfg.Client.Respond(context.Background(), cfg.Session, provider.Request{Role: cfg.Role, Instructions: loop.DefaultInstructions, Input: []any{map[string]any{"role": "user", "content": "hello"}}, Tools: s.Definitions(), CacheID: s.ID()}, nil)
	if err != nil {
		t.Fatal(err)
	}
	ref := len(f.rawBodies) - 1
	if !bytes.Equal(f.rawBodies[index], f.rawBodies[ref]) {
		t.Fatalf("body differs\nsession: %s\nreference: %s", f.rawBodies[index], f.rawBodies[ref])
	}
	if !reflect.DeepEqual(f.headers[index], f.headers[ref]) {
		t.Fatalf("headers differ: %v vs %v", f.headers[index], f.headers[ref])
	}
}

func TestSessionCacheIdentityIsTheSessionID(t *testing.T) {
	for _, role := range cacheProfiles {
		t.Run(role.Provider, func(t *testing.T) {
			f, cfg := cacheSetup(t, role, 4)
			a, err := loop.NewSession(cfg)
			if err != nil {
				t.Fatal(err)
			}
			b, err := loop.NewSession(cfg)
			if err != nil {
				t.Fatal(err)
			}
			if a.ID() == b.ID() {
				t.Fatal("same session IDs")
			}
			cacheRound(t, a)
			cacheRound(t, b)
			cacheCheck(t, f, 0, role, a.ID())
			cacheCheck(t, f, 1, role, b.ID())
			cacheReference(t, f, cfg, a, 0)
			cacheReference(t, f, cfg, b, 1)
		})
	}
}

func TestResumedSessionKeepsItsSessionIDAsCacheIdentity(t *testing.T) {
	for _, role := range cacheProfiles {
		t.Run(role.Provider, func(t *testing.T) {
			f, cfg := cacheSetup(t, role, 2)
			cfg.Dir = t.TempDir()
			s, err := loop.NewSession(cfg)
			if err != nil {
				t.Fatal(err)
			}
			cacheRound(t, s)
			data, err := os.ReadFile(filepath.Join(cfg.Dir, "session.json"))
			if err != nil {
				t.Fatal(err)
			}
			var transcript map[string]any
			if err := json.Unmarshal(data, &transcript); err != nil {
				t.Fatal(err)
			}
			if transcript["session_id"] != s.ID() {
				t.Fatal("transcript identity changed")
			}
			r, err := loop.ResumeSession(cfg)
			if err != nil {
				t.Fatal(err)
			}
			if r.ID() != s.ID() {
				t.Fatal("resume changed session ID")
			}
			cacheRound(t, r)
			cacheCheck(t, f, 1, role, s.ID())
		})
	}
}

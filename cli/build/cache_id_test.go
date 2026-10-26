package build

import (
	"strings"
	"testing"

	"kogen-loop/provider"
	"kogen/agent"
	"kogen/project"
)

// Every model conversation of a Build has one prompt-cache identity: created when the
// conversation starts, kept in the checkpoint and sent with every request of it.

func cacheKeys(f *fakeProvider, want func(req map[string]any) bool) []string {
	var keys []string
	for _, req := range f.requests() {
		if want(req) {
			key, _ := req["prompt_cache_key"].(string)
			keys = append(keys, key)
		}
	}
	return keys
}

func TestTheBuilderAndEachReviewHaveTheirOwnSavedCacheIdentity(t *testing.T) {
	// Intent go-core-migration, Prompt caching: one identity per conversation, saved in its checkpoint, never shared
	e := newEnv(t)
	f := e.prov
	f.then(
		f.calls("shell", map[string]any{"command": "echo one"}),
		f.calls("write_file", map[string]any{"path": "app.txt", "content": "candidate\n"}, "finish", map[string]any{"summary": "done"}),
		f.calls("shell", map[string]any{"command": "echo reviewer"}),
		submit(f, "approve"),
	)
	a := e.reviewed()
	if a.exit != 0 {
		t.Fatalf("exit %d\n%s", a.exit, a.shown())
	}
	builder := cacheKeys(f, func(req map[string]any) bool { return requestInstructions(req) != reviewerInstructions() })
	reviewer := cacheKeys(f, func(req map[string]any) bool { return requestInstructions(req) == reviewerInstructions() })
	if len(builder) != 2 || len(reviewer) != 2 {
		t.Fatalf("builder %d reviewer %d requests", len(builder), len(reviewer))
	}
	for _, key := range append(append([]string{}, builder...), reviewer...) {
		if key == "" || len(key) > provider.MaxCacheID {
			t.Fatalf("cache key %q", key)
		}
	}
	if builder[0] != builder[1] || reviewer[0] != reviewer[1] {
		t.Fatalf("a conversation changed its identity: %v %v", builder, reviewer)
	}
	if builder[0] == reviewer[0] {
		t.Fatal("the builder and the reviewer share an identity")
	}
	_, state := e.checkpoint(e.onlyRun())
	ids := state["cache_ids"].(map[string]any)
	eq(t, "saved ids", ids, map[string]any{"build": builder[0], "review-1": reviewer[0]})
	// Every request carries it where the provider reads it: the body and the session header.
	for _, req := range f.requests() {
		if _, ok := req["prompt_cache_options"]; ok {
			t.Fatal("prompt_cache_options sent")
		}
	}
}

func reviewerInstructions() string { return agent.Prompt(agent.Reviewer) }

func TestAResumedBuildKeepsItsConversationsIdentity(t *testing.T) {
	// Intent go-core-migration, Prompt caching: the identity is reused for every later request, including explicit resume
	e := newEnv(t)
	opened := make(chan struct{})
	f := e.prov
	f.then(f.calls("shell", map[string]any{"command": "echo before"}), hang(opened))
	a, done := e.start()
	<-opened
	a.s.Interrupt("SIGINT")
	<-done
	id := e.onlyRun()
	_, state := e.checkpoint(id)
	saved := state["cache_ids"].(map[string]any)["build"].(string)
	f.then(f.calls("write_file", map[string]any{"path": "app.txt", "content": "candidate\n"}, "finish", map[string]any{"summary": "done"}))
	r := e.resume(id)
	if r.exit != 0 {
		t.Fatalf("exit %d\n%s", r.exit, r.shown())
	}
	keys := cacheKeys(f, func(map[string]any) bool { return true })
	eq(t, "requests", len(keys), 3)
	for _, k := range keys {
		eq(t, "key", k, saved)
	}
	child := legacyChild(t, e, id)
	_, resumed := e.checkpoint(child)
	eq(t, "child ids", resumed["cache_ids"].(map[string]any)["build"], any(saved))
}

func TestAWorkingContextResetKeepsTheConversationsIdentity(t *testing.T) {
	// Intent go-core-migration, Prompt caching: working-context resets keep the identity (instructions and tools stay the same)
	e := newEnv(t)
	f := e.prov
	big := map[string]any{"command": "head -c 20000 /dev/zero | tr '\\0' x"}
	for i := 0; i < 40; i++ {
		f.then(f.calls("shell", big))
	}
	f.then(f.calls("write_file", map[string]any{"path": "app.txt", "content": "candidate\n"}, "finish", map[string]any{"summary": "done"}))
	a := e.build()
	if a.exit != 0 {
		t.Fatalf("exit %d\n%s", a.exit, a.shown())
	}
	contains(t, "progress", a.errs.String(), "kogen: build local reset ")
	reqs := f.requests()
	first := reqs[0]
	for i, req := range reqs {
		eq(t, "key", req["prompt_cache_key"], first["prompt_cache_key"])
		eq(t, "instructions", req["instructions"], first["instructions"])
		eq(t, "tools", canonical(req["tools"]), canonical(first["tools"]))
		if _, ok := req["prompt_cache_options"]; ok {
			t.Fatalf("request %d sent prompt_cache_options", i)
		}
	}
}

func TestACacheIdentityIsPerConversationAndCreatedOnce(t *testing.T) {
	// Intent go-core-migration, Prompt caching: different conversations never share one
	b := &Attempt{}
	build := b.cacheID("build")
	if build == "" || len(build) > provider.MaxCacheID || b.cacheID("build") != build {
		t.Fatalf("builder identity %q", build)
	}
	b.Review = 1
	first := b.cacheID("review")
	b.Review = 2
	second := b.cacheID("review")
	b.Review = 1
	if first == second || first == build || second == build || b.cacheID("review") != first {
		t.Fatalf("identities %q %q %q", build, first, second)
	}
	eq(t, "saved", b.CacheIDs, map[string]string{"build": build, "review-1": first, "review-2": second})
	for _, id := range []string{build, first, second} {
		if strings.ContainsAny(id, " /:") && !strings.HasPrefix(id, "conversation-") {
			t.Fatalf("identity %q", id)
		}
	}
	// Without a saved identity (a checkpoint of the Elixir Kogen) one is created once and kept.
	legacy := &Attempt{State: State{Config: &project.Config{}}}
	id := legacy.cacheID("build")
	eq(t, "kept", legacy.cacheID("build"), id)
}

func TestAnAnthropicResponseKeepsUnreportedCountsUnknown(t *testing.T) {
	// ExUnit: lib/kogen/anthropic.ex usage/1 (input is the sum of its reported parts; reasoning is never reported)
	role := project.Role{Provider: "anthropic", Model: "claude-sonnet-5-5", Effort: "high"}
	in, cached, out := 12, 5, 3
	got := responseTokens(role, &provider.Response{Known: provider.KnownUsage{Input: &in, Cached: &cached, Output: &out}})
	eq(t, "line", got.Line(), "input=12 cached=5 output=3 reasoning=unknown")
	none := responseTokens(role, &provider.Response{})
	eq(t, "none", none.Line(), "input=unknown cached=unknown output=unknown reasoning=unknown")
	chat := responseTokens(project.Role{Model: "gpt-6.1-sol", Effort: "medium"}, &provider.Response{Usage: provider.Usage{Input: 4, Output: 2}})
	eq(t, "chatgpt", chat.Line(), "input=4 cached=0 output=2 reasoning=0")
}

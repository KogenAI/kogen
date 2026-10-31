package shape

import (
	"strings"
	"testing"
)

func cacheKeys(reqs []map[string]any) []string {
	var keys []string
	for _, r := range reqs {
		k, _ := r["prompt_cache_key"].(string)
		keys = append(keys, k)
	}
	return keys
}

func TestAShapeConversationKeepsOneCacheIdentityForEveryRequest(t *testing.T) {
	parallel(t)
	f := newShpFx(t,
		shpAnswer(shpCall("c1", "submit", shpFiles())), // refused (uninspected): a second request follows
		shpSubmit("c2", shpFiles()),
		shpAck("c3"))
	if exit, err := f.shape("Add calc.is_even(n)."); err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
	}
	keys := cacheKeys(f.Prov.requests())
	if len(keys) != 3 || keys[0] == "" || len(keys[0]) > 64 || keys[0] != keys[1] || keys[1] != keys[2] {
		t.Fatalf("cache keys %q", keys)
	}
	events := shpNamed(f.events(), "cache_identity")
	if len(events) != 1 || events[0]["owner"] != "shape" || events[0]["id"] != keys[0] {
		t.Fatalf("saved identities %v, wire key %q", events, keys[0])
	}
	// A second invocation is another conversation.
	g := newShpFx(t, shpSubmit("c1", shpFiles()), shpAck("c2"))
	if _, err := g.shape("Add calc.is_even(n)."); err != nil {
		t.Fatal(err)
	}
	if other := cacheKeys(g.Prov.requests())[0]; other == keys[0] {
		t.Fatalf("two conversations share the identity %q", other)
	}
}

func TestAShapeConversationKeepsItsIdentityAcrossAWorkingWindowReset(t *testing.T) {
	parallel(t)
	f := newShpFx(t, readPadding(40)...)
	seedPadding(f)
	f.Prov.mu.Lock()
	f.Prov.seq = append(f.Prov.seq, shpSubmit("c1", shpFiles()), shpAck("c2"))
	f.Prov.mu.Unlock()
	if exit, err := f.shape("Add calc.is_even(n)."); err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
	}
	if len(shpNamed(f.events(), "working_context_reset")) == 0 {
		t.Fatal("the conversation never reset its window")
	}
	keys := cacheKeys(f.Prov.requests())
	for _, k := range keys {
		if k == "" || k != keys[0] {
			t.Fatalf("keys %q", keys)
		}
	}
}

func TestEveryShapeWorkerHasItsOwnCacheIdentity(t *testing.T) {
	parallel(t)
	f := newShpFx(t)
	f.withWorkers()
	jobs := []any{shpJob("one", "read", []any{"app.txt"}), shpJob("two", "read", []any{"app.txt"})}
	f.Prov.route = func(req map[string]any) *shpStep {
		switch id := workerJobID(req); id {
		case "one", "two":
			var st shpStep
			if len(shpOutputs(req)) == 0 {
				st = shpAnswer(shpCall(id+"-r", "read_file", map[string]any{"path": "app.txt"}))
			} else {
				st = shpWorkerResult(id+"-done", "inspected")
			}
			return &st
		}
		return nil
	}
	f.Prov.seq = []shpStep{
		shpAnswer(shpCall("b1", "shape_batch", map[string]any{"brief": f.brief(), "jobs": jobs})),
		shpSubmit("q", map[string]any{"questions": []any{shpQuestion("Q?")}}),
	}
	if exit, err := f.shape("Add calc.is_even(n)."); err != nil || exit != 5 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
	}
	perConversation := map[string][]string{}
	for _, r := range f.Prov.requests() {
		id := workerJobID(r)
		k, _ := r["prompt_cache_key"].(string)
		perConversation[id] = append(perConversation[id], k)
	}
	seen := map[string]string{}
	for id, keys := range perConversation {
		if id == "" && len(keys) != 2 || id != "" && len(keys) != 2 {
			t.Fatalf("conversation %q made %d requests", id, len(keys))
		}
		for _, k := range keys {
			if k == "" || k != keys[0] {
				t.Fatalf("conversation %q keys %q", id, keys)
			}
		}
		if other, dup := seen[keys[0]]; dup {
			t.Fatalf("conversations %q and %q share an identity", id, other)
		}
		seen[keys[0]] = id
	}
	if len(seen) != 3 {
		t.Fatalf("%d distinct conversations, want the shaper and two workers: %v", len(seen), seen)
	}
	owners := map[string]bool{}
	for _, e := range shpNamed(f.events(), "cache_identity") {
		owners[e["owner"].(string)] = true
	}
	if !owners["shape"] || !owners["worker one"] || !owners["worker two"] {
		t.Fatalf("saved identities %v", owners)
	}
}

func TestARefinementKeepsOneCacheIdentityOfItsOwn(t *testing.T) {
	parallel(t)
	f := newRefFx(t, refOpts{},
		refProbe("c1", "true"),
		refSubmit("c2", refIntentPath, refTitled))
	if exit, err := f.refine(f.hash0); err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
	}
	keys := cacheKeys(f.Prov.requests())
	if len(keys) != 2 || keys[0] == "" || keys[0] != keys[1] || strings.TrimSpace(keys[0]) != keys[0] {
		t.Fatalf("keys %q", keys)
	}
	events := 0
	for _, e := range f.evidenceEvents() {
		if e["event"] == "cache_identity" {
			events++
			if e["owner"] != "refine" || e["id"] != keys[0] {
				t.Fatalf("saved identity %v, wire key %q", e, keys[0])
			}
		}
	}
	if events != 1 {
		t.Fatalf("%d saved identities", events)
	}
}

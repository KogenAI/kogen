package provider

import (
	"encoding/json"
	"os"
	"reflect"
	"strings"
	"testing"
)

// The vectors are produced by Kogen.PromptCache.prepare in the Elixir implementation
// (mix run --no-start): the fingerprints of the frozen front are the same digests (the
// request bodies and the conversation key changed with the Intent's caching contract).
func TestFingerprintsMatchElixirVectors(t *testing.T) {
	data, err := os.ReadFile("testdata/elixir_prompt_cache.json")
	if err != nil {
		t.Fatal(err)
	}
	v, err := decodeJSON(data)
	if err != nil {
		t.Fatal(err)
	}
	for _, raw := range v.([]any) {
		c := raw.(map[string]any)
		name := c["name"].(string)
		t.Run(name, func(t *testing.T) {
			input, _ := asList(c["input"])
			tools, _ := asList(c["tools"])
			ev := newEvidence("conversation-x", "implicit", nil, false, c["policy"].(string), input, tools)
			got, _ := decodeJSON(mustEncode(ev.meta["fingerprints"]))
			if !reflect.DeepEqual(got, c["fingerprints"]) {
				t.Errorf("fingerprints\n got %s\nwant %s", jsonOf(t, got), jsonOf(t, c["fingerprints"]))
			}
		})
	}
}

func TestEncodeJSONMatchesElixir(t *testing.T) {
	// Expected values were printed by Elixir's JSON.encode!.
	floats := map[float64]string{
		0.0001: "0.0001", 0.001: "0.001", 0.00012: "1.2e-4", 1e15: "1.0e15", 1e16: "1.0e16",
		123456789012345680.0: "1.2345678901234568e17", 1.5e300: "1.5e300", 5e-324: "5.0e-324", 0.1: "0.1",
		2.5e-5: "2.5e-5", 1234567.0: "1234567.0", 1e21: "1.0e21", 9.99e20: "9.99e20", 0.00009: "9.0e-5",
		1200.0: "1.2e3", 12000.0: "1.2e4", 100.0: "100.0", 1000.0: "1.0e3", 123400.0: "1.234e5", 0.5: "0.5",
		3.14159: "3.14159", 12345678.9: "12345678.9", 1e10: "1.0e10", 12345670.0: "12345670.0", 1.234567e8: "1.234567e8",
		1.5: "1.5", 9007199254740900.0: "9007199254740900.0", 9.123456789012345e15: "9.123456789012344e15", 1234567890123456.8: "1234567890123456.8", 1.2345678901234567e-4: "1.2345678901234567e-4", 0.000001: "1.0e-6", 123456789.123: "123456789.123", 1e-7: "1.0e-7", 0.0012: "0.0012",
	}
	for f, want := range floats {
		if got := string(mustEncode(f)); got != want {
			t.Errorf("float %v = %s, want %s", f, got, want)
		}
	}
	s := "a\u0001b\u001fc\u007fd  \b\f\n\r\t/<>&é😀\"\\"
	want := `"a\u0001b\u001Fc` + "\u007f" + `d` + "  " + `\b\f\n\r\t/<>&é😀\"\\"`
	if got := string(mustEncode(s)); got != want {
		t.Errorf("string = %s, want %s", got, want)
	}
	m := map[string]any{"b": int64(1), "a": []any{nil, true, "x"}, "Z": map[string]any{}}
	if got := string(mustEncode(m)); got != `{"Z":{},"a":[null,true,"x"],"b":1}` {
		t.Errorf("object = %s", got)
	}
	if got := string(mustEncode(struct {
		A int `json:"a"`
	}{3})); got != `{"a":3}` {
		t.Errorf("struct = %s", got)
	}
}

func TestDecodeKeepsIntegersAndFloatsApart(t *testing.T) {
	v, _ := decodeJSON([]byte(`{"i":5,"f":5.0,"e":1e3,"big":12345678901234567890}`))
	if got := string(mustEncode(v)); got != `{"big":12345678901234567890,"e":1.0e3,"f":5.0,"i":5}` {
		t.Fatalf("roundtrip = %s", got)
	}
}

func contractInput(suffix string) []any {
	return []any{map[string]any{"role": "user", "content": ContractBlocks("complete Δ contract\n", "# Files\n"+suffix)}}
}

// prompt_cache_test: the fingerprints isolate dynamic bytes from the frozen front.
func TestStableBoundariesRetainAuthorityAndIsolateDynamicBytes(t *testing.T) {
	tools := []any{map[string]any{"type": "function", "parameters": map[string]any{"type": "object"}}}
	fps := func(policy string, input, tools []any) map[string]any {
		return newEvidence("c", "implicit", nil, false, policy, input, tools).meta["fingerprints"].(map[string]any)
	}
	a, b := fps("policy", contractInput("a"), tools), fps("policy", contractInput("b"), tools)
	if !reflect.DeepEqual(a, b) {
		t.Fatal("fingerprints differ for dynamic-only change")
	}
	c := fps("changed policy", contractInput("b"), tools)
	if reflect.DeepEqual(c["policy"], b["policy"]) || !reflect.DeepEqual(c["contract"], b["contract"]) || !reflect.DeepEqual(c["schema"], b["schema"]) {
		t.Fatal("changed policy must change only the policy and prefix fingerprints")
	}
	d := fps("policy", contractInput("b"), []any{map[string]any{"parameters": map[string]any{}}})
	if reflect.DeepEqual(d["tools"], b["tools"]) || reflect.DeepEqual(d["schema"], b["schema"]) {
		t.Fatal("changed tools must change tools and schema fingerprints")
	}
}

func TestCacheStatesSurviveACheckpoint(t *testing.T) {
	cache := NewCache(map[string]CacheState{"k": {ID: "conversation-1", Response: "resp_1"}, "u": {ID: "conversation-2", Unsupported: true}})
	data, err := json.Marshal(cache.States())
	if err != nil {
		t.Fatal(err)
	}
	if want := `{"k":{"id":"conversation-1","unsupported":false,"response":"resp_1"},"u":{"id":"conversation-2","unsupported":true,"response":null}}`; string(data) != want {
		t.Fatalf("checkpoint form\n got %s\nwant %s", data, want)
	}
	var back map[string]CacheState
	if err := json.Unmarshal(data, &back); err != nil || !reflect.DeepEqual(back, cache.States()) {
		t.Fatalf("restore = %v, %v", back, err)
	}
	if !ValidCacheStates(back) || ValidCacheStates(map[string]CacheState{"k": {ID: ""}}) || ValidCacheStates(map[string]CacheState{"k": {ID: strings.Repeat("x", 257)}}) {
		t.Fatal("ValidCacheStates")
	}
	// The states a restored Cache holds are the ones the next request continues from.
	role := Role{Provider: "supergrok", Model: "grok-4.7", Effort: "low"}
	key := conversationKey(role, "scope")
	restored := NewCache(map[string]CacheState{key: {ID: "conversation-saved"}})
	if got := restored.Identity(role, "scope"); got != "conversation-saved" {
		t.Fatalf("restored identity = %s", got)
	}
}

// prompt_cache_test: optional diagnostics are bounded classified evidence, not text.
func TestCacheDiagnosticsAreClassifiedEvidence(t *testing.T) {
	for _, typ := range []string{"cache_hit", "cache_miss", "comparison_response_not_found", "unavailable"} {
		got := cacheDiagnostics(map[string]any{"type": typ, "reason": "secret", "raw": "secret"})
		if !reflect.DeepEqual(got, map[string]any{"type": typ, "reason": "other"}) {
			t.Fatalf("%s: %v", typ, got)
		}
	}
	if cacheDiagnostics([]any{}) != nil || cacheDiagnostics(nil) != nil {
		t.Fatal("non-objects must give no diagnostics")
	}
	got := cacheDiagnostics(map[string]any{"type": "cache_hit", "reason": "expired", "cache_hit_tokens": int64(5), "cache_missed_tokens": int64(-1), "comparison_reusable_tokens": "7"})
	if !reflect.DeepEqual(got, map[string]any{"type": "cache_hit", "reason": "expired", "cache_hit_tokens": int64(5)}) {
		t.Fatalf("counts = %v", got)
	}
	if cacheDiagnostics(map[string]any{"type": strings.Repeat("x", 3000)}) != nil {
		t.Fatal("oversized diagnostics must be dropped")
	}
}

// prompt_cache_test: usage validates disjoint writes and subset reasoning without clamping.
func TestUsageValidatesDisjointWritesAndSubsetReasoning(t *testing.T) {
	n := func(i int) *int { return &i }
	valid := KnownUsage{Input: n(100), Cached: n(20), Write: n(80), Write30m: n(40), Write12h: n(40), Output: n(10), Reasoning: n(10)}
	if valid.State() != UsageKnown {
		t.Fatal(valid.State())
	}
	for name, mod := range map[string]func(k *KnownUsage){
		"cached>": func(k *KnownUsage) { k.Cached = n(21) }, "12h": func(k *KnownUsage) { k.Write12h = n(41) },
		"reasoning": func(k *KnownUsage) { k.Reasoning = n(11) },
	} {
		k := valid
		mod(&k)
		if k.State() != UsageInconsistent {
			t.Errorf("%s: %s", name, k.State())
		}
	}
	for name, raw := range map[string]rawUsage{
		"negative": {input: int64(-1)}, "string": {write: "invalid"}, "float": {output: 1.5}, "map": {write: map[string]any{"raw": "x"}},
	} {
		if raw.state() != UsageInconsistent {
			t.Errorf("%s not inconsistent", name)
		}
	}
	k := valid
	k.Write, k.Write30m, k.Write12h = nil, nil, nil
	if k.State() != UsagePartial || (KnownUsage{}).State() != UsageUnknown {
		t.Fatal("partial/unknown states")
	}
	if got := (Usage{1, 2, 3, 4}).Add(Usage{1, 1, 1, 1}); got != (Usage{2, 3, 4, 5}) || got.Line() != "input=2 cached=3 output=4 reasoning=5" || got.Total() != 6 {
		t.Fatal(got)
	}
}

// provider_test: Shape includes enabled workers (the role list is the project package's);
// the provider part is the name of each role.
func TestRoleNames(t *testing.T) {
	roles := []Role{{Model: "m"}, {Provider: "supergrok"}, {Provider: "chatgpt"}, {Provider: ""}, {Provider: "opencode-go"}, {Provider: "anthropic"}}
	var got []string
	for _, r := range roles {
		got = append(got, Name(r))
	}
	if !reflect.DeepEqual(got, []string{"chatgpt", "supergrok", "chatgpt", "chatgpt", "opencode-go", "anthropic"}) {
		t.Fatal(got)
	}
	if _, ok := Lookup("grok"); ok {
		t.Fatal("unknown provider found")
	}
	names := []string{}
	for _, p := range Catalog() {
		names = append(names, p.Name)
	}
	if !reflect.DeepEqual(names, []string{"chatgpt", "supergrok", "opencode-go", "anthropic", "openai-compatible"}) {
		t.Fatal(names)
	}
}

func TestFingerprintHelper(t *testing.T) {
	d := Fingerprint("policy text Δ\n")
	if d == nil || d.Bytes != 15 || d.SHA256 != "146628eb5e4754563588d1a15cd990340d4cf89897d4ecf18be0c0ed2c409489" {
		t.Fatalf("%+v", d)
	}
	if Fingerprint(nil) != nil {
		t.Fatal("nil value")
	}
	// Values hash as their Elixir-encoded JSON.
	j := Fingerprint(map[string]any{"b": []any{}, "a": 1})
	want := Fingerprint(`{"a":1,"b":[]}`)
	if *j != *want {
		t.Fatalf("%+v vs %+v", j, want)
	}
	data, _ := json.Marshal(d)
	if string(data) != `{"sha256":"146628eb5e4754563588d1a15cd990340d4cf89897d4ecf18be0c0ed2c409489","bytes":15}` {
		t.Fatal(string(data))
	}
}

func TestLegacyOptionsSuppressionDoesNotSuppressNewRoutingKey(t *testing.T) {
	req := Request{Role: Role{Model: "gpt-6.1-sol", Effort: "high"}, Scope: "legacy conversation"}
	cache := NewCache(nil)
	key, original := cache.resolve(req)
	legacy := original
	legacy.Control = ""
	legacy.Unsupported = true
	cache = NewCache(map[string]CacheState{key: legacy})
	_, current := cache.resolve(req)
	if current.ID != original.ID || current.Unsupported || current.Control != "prompt_cache_key" {
		t.Fatalf("legacy restore: %+v", current)
	}
	current.Unsupported = true
	encoded, err := json.Marshal(current)
	if err != nil {
		t.Fatal(err)
	}
	var restored CacheState
	if err = json.Unmarshal(encoded, &restored); err != nil {
		t.Fatal(err)
	}
	cache = NewCache(map[string]CacheState{key: restored})
	_, current = cache.resolve(req)
	if !current.Unsupported {
		t.Fatal("actual key refusal was lost on restore")
	}
}

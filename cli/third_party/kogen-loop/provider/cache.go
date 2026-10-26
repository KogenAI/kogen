package provider

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"sync"
)

// Prompt caching (Intent go-core-migration, "Prompt caching"): every model conversation has
// one cache identity of at most MaxCacheID characters, created when the conversation starts
// and reused for every later request of it (retries, working-context resets, resume).
// The caller keeps it — pass it in Request.CacheID, or let a Cache hold it per conversation
// scope and store Cache.States() in the checkpoint. The provider package decides only where
// the identity goes on the wire:
//
//	ChatGPT      body prompt_cache_key and headers session_id, conversation_id
//	SuperGrok    body prompt_cache_key
//	OpenCode Go  header x-opencode-session
//	Anthropic    no routing value; cache_control ephemeral on the last tool, the last
//	             system block and the last block of the newest message
//
// No provider is sent prompt_cache_options or prompt_cache_breakpoint.

// MaxCacheID is the longest cache identity put on the wire.
const MaxCacheID = 64

// CacheState is the memory of one independent conversation: its cache identity and whether
// ChatGPT or SuperGrok refused prompt_cache_key for it. A Build checkpoint stores these by key. Response
// is kept only so that version-3 checkpoints from the Elixir Kogen still read; it is never
// sent.
type CacheState struct {
	ID          string
	Unsupported bool
	Control     string
	Response    string // "" = none
}

type cacheStateJSON struct {
	ID          string  `json:"id"`
	Unsupported bool    `json:"unsupported"`
	Control     string  `json:"control,omitempty"`
	Response    *string `json:"response"`
}

// MarshalJSON writes the checkpoint form {"id","unsupported","response"|null}.
func (s CacheState) MarshalJSON() ([]byte, error) {
	j := cacheStateJSON{ID: s.ID, Unsupported: s.Unsupported, Control: s.Control}
	if s.Response != "" {
		j.Response = &s.Response
	}
	return json.Marshal(j)
}

// UnmarshalJSON reads the checkpoint form.
func (s *CacheState) UnmarshalJSON(b []byte) error {
	var j cacheStateJSON
	if err := json.Unmarshal(b, &j); err != nil {
		return err
	}
	*s = CacheState{ID: j.ID, Unsupported: j.Unsupported, Control: j.Control}
	if j.Response != nil {
		s.Response = *j.Response
	}
	return nil
}

// Valid is the checkpoint check: IDs are 1..256 bytes (older checkpoints may hold longer
// identities than MaxCacheID; the wire then carries a stable 64-character digest of it).
func (s CacheState) Valid() bool {
	return len(s.ID) >= 1 && len(s.ID) <= 256 && len(s.Response) <= 256
}

// ValidCacheStates reports whether every restored state is usable.
func ValidCacheStates(states map[string]CacheState) bool {
	for k, s := range states {
		if k == "" || !s.Valid() {
			return false
		}
	}
	return true
}

// NewCacheID is a fresh cache identity for a new conversation (29 characters, no clock
// time, repository path or personal identifier in it).
func NewCacheID() string { return newID("conversation") }

// wireID is the identity as it goes on the wire: at most MaxCacheID characters.
func wireID(id string) string {
	if len(id) <= MaxCacheID {
		return id
	}
	sum := sha256.Sum256([]byte(id))
	return hex.EncodeToString(sum[:])[:MaxCacheID]
}

// Cache is the set of conversation states a caller keeps across requests. It is safe for
// concurrent use; the caller stores States() in the Build checkpoint and gives them back
// with NewCache after a resume.
type Cache struct {
	mu     sync.Mutex
	states map[string]CacheState
}

// NewCache returns a Cache holding a copy of states (nil for none).
func NewCache(states map[string]CacheState) *Cache {
	c := &Cache{states: map[string]CacheState{}}
	for k, v := range states {
		c.states[k] = v
	}
	return c
}

// States returns a copy of the current states.
func (c *Cache) States() map[string]CacheState {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make(map[string]CacheState, len(c.states))
	for k, v := range c.states {
		out[k] = v
	}
	return out
}

func (c *Cache) put(key string, s CacheState) {
	c.mu.Lock()
	c.states[key] = s
	c.mu.Unlock()
}

// conversationKey names a conversation: its provider, model and the caller's scope (a Build's
// [root run, role, review number], a shaping evidence directory, a batch job ID). A working
// window or a retry is not part of it, so they keep the identity; a different provider, model
// or scope never shares one.
func conversationKey(role Role, scope any) string {
	return fingerprint([]any{Name(role), role.Model, scope}).(map[string]any)["sha256"].(string)
}

// Identity is the cache identity of the conversation (role, scope): the saved one, or a new
// one created and kept. Callers keep it across a resume by storing States() with the
// checkpoint and restoring it with NewCache, or hold the returned value themselves and pass
// it as Request.CacheID.
func (c *Cache) Identity(role Role, scope any) string {
	st, _ := c.conversation(conversationKey(role, scope))
	return wireID(st.ID)
}

// conversation returns the state under key, creating it (with a new identity) when absent.
func (c *Cache) conversation(key string) (CacheState, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	st, ok := c.states[key]
	if !ok || st.ID == "" {
		st = CacheState{ID: NewCacheID()}
		c.states[key] = st
	}
	return st, ok
}

// fingerprint is the local-byte evidence of a value: SHA-256 of its UTF-8 bytes (a string
// as is, anything else as its JSON encoding) and the byte count; nil stays nil.
func fingerprint(v any) any {
	var data []byte
	switch x := v.(type) {
	case nil:
		return nil
	case string:
		data = []byte(x)
	default:
		data = mustEncode(v)
	}
	sum := sha256.Sum256(data)
	return map[string]any{"sha256": hex.EncodeToString(sum[:]), "bytes": len(data)}
}

// Digest is local-byte evidence of a value: the SHA-256 of its UTF-8 bytes and their count.
type Digest struct {
	SHA256 string `json:"sha256"`
	Bytes  int    `json:"bytes"`
}

// Fingerprint is the evidence Kogen records for text and values it does not keep (tool
// arguments and results, policy, contract): a string is hashed as is, any other value as
// its JSON encoding (object keys sorted); nil gives nil.
func Fingerprint(v any) *Digest {
	m, ok := fingerprint(v).(map[string]any)
	if !ok {
		return nil
	}
	return &Digest{SHA256: m["sha256"].(string), Bytes: m["bytes"].(int)}
}

// ContractBlocks are the two input_text blocks of a contract message: the stable
// authority and the dynamic evidence behind it. No cache marker rides on them; the whole
// request prefix is what the provider matches.
func ContractBlocks(stable, dynamic string) []any {
	return []any{
		map[string]any{"type": "input_text", "text": stable},
		map[string]any{"type": "input_text", "text": dynamic},
	}
}

func newID(prefix string) string {
	b := make([]byte, 8)
	rand.Read(b)
	return prefix + "-" + hex.EncodeToString(b)
}

// contractText is the stable text a conversation opens with: the first message's string
// content or first input_text block; nil when it opens otherwise.
func contractText(input []any) *string {
	if len(input) == 0 {
		return nil
	}
	first, ok := asMap(input[0])
	if !ok {
		return nil
	}
	switch content := first["content"].(type) {
	case string:
		return &content
	default:
		list, ok := asList(content)
		if !ok || len(list) == 0 {
			return nil
		}
		if b, ok := asMap(list[0]); ok && b["type"] == "input_text" {
			if stable, ok := b["text"].(string); ok {
				return &stable
			}
		}
	}
	return nil
}

// evidence is the cache situation of one request: the record fields conversation_id, cache
// and fingerprints. The cache map starts as requested and becomes applied once an answer
// completes; the fingerprints are local-byte evidence of the frozen front of the request.
type evidence struct {
	meta  map[string]any
	cache map[string]any
}

func newEvidence(id string, mode any, boundaries []any, unsupported bool, policy string, input, tools []any) evidence {
	status := "requested"
	if unsupported {
		status, mode = "unsupported", nil
	}
	if boundaries == nil {
		boundaries = []any{}
	}
	cache := map[string]any{
		"configured_mode":        mode,
		"configured_ttl":         nil,
		"applied_mode":           nil,
		"applied_ttl":            nil,
		"status":                 status,
		"boundaries":             boundaries,
		"comparison_response_id": nil,
		"diagnostics":            nil,
	}
	schema := make([]any, len(tools))
	for i, t := range tools {
		picked := map[string]any{}
		if m, ok := asMap(t); ok {
			for _, k := range []string{"parameters", "output_schema", "response_format"} {
				if v, ok := m[k]; ok {
					picked[k] = v
				}
			}
		}
		schema[i] = picked
	}
	toolList := tools
	if toolList == nil {
		toolList = []any{}
	}
	var contract any
	if t := contractText(input); t != nil {
		contract = *t
	}
	return evidence{
		cache: cache,
		meta: map[string]any{
			"conversation_id": id,
			"cache":           cache,
			"fingerprints": map[string]any{
				"policy":   fingerprint(policy),
				"tools":    fingerprint(toolList),
				"schema":   fingerprint(schema),
				"contract": fingerprint(contract),
				"prefix":   fingerprint([]any{policy, toolList, contract}),
			},
		},
	}
}

// identifier is a bounded analytical identifier: a string of 1..256 bytes, else "".
func identifier(v any) string {
	if s, ok := v.(string); ok && len(s) >= 1 && len(s) <= 256 {
		return s
	}
	return ""
}

func identifierOrNil(v any) any {
	if s := identifier(v); s != "" {
		return s
	}
	return nil
}

// cacheDiagnostics is bounded classified evidence from the optional provider diagnostics:
// a type, a reason (each from a fixed list, else "other") and nonnegative counts.
func cacheDiagnostics(v any) any {
	m, ok := asMap(v)
	if !ok || len(mustEncode(m)) > 2048 {
		return nil
	}
	classify := func(value any, allowed ...string) string {
		for _, a := range allowed {
			if value == a {
				return a
			}
		}
		return "other"
	}
	out := map[string]any{
		"type":   classify(m["type"], "cache_hit", "cache_miss", "comparison_response_not_found", "unavailable"),
		"reason": classify(m["reason"], "tools_changed", "policy_changed", "prefix_changed", "schema_changed", "contract_changed", "unavailable", "expired"),
	}
	for _, k := range []string{"comparison_reusable_tokens", "cache_missed_tokens", "cache_hit_tokens"} {
		if n, ok := asInt(m[k]); ok && n >= 0 {
			out[k] = n
		}
	}
	return out
}

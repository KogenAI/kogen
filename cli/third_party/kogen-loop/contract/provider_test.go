package contract_test

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/KogenAI/kogen-loop/provider"
	"github.com/KogenAI/kogen-loop/sys"
)

const fixtureVersion = "kogen dev+12345678 (test)"

// chatgptRole is the role of the ChatGPT requests of this file.
var chatgptRole = provider.Role{Provider: "chatgpt", Model: "gpt-6.1-sol", Effort: "medium"}

// noSleep is the Client.Sleep of every test here: backoff and lock waits take no time.
func noSleep(context.Context, time.Duration) error { return nil }

// attempts is a provider.Observer that keeps the attempt records.
type attempts struct {
	mu   sync.Mutex
	recs []map[string]any
}

func (a *attempts) Attempt(record map[string]any) {
	a.mu.Lock()
	a.recs = append(a.recs, record)
	a.mu.Unlock()
}

func (a *attempts) records() []map[string]any {
	a.mu.Lock()
	defer a.mu.Unlock()
	return append([]map[string]any(nil), a.recs...)
}

// chatgptWorld is a session with a seeded ChatGPT login, a client whose Sleep takes no time
// and a fake provider the session's KOGEN_PROVIDER_URL and KOGEN_AUTH_URL point at.
func chatgptWorld(t *testing.T, script ...http.HandlerFunc) (*provider.Client, *sys.Session, *fakeProvider, string) {
	t.Helper()
	f := newFakeProvider(t, script...)
	s, _, home := newSession(t, f.env()...)
	seedChatGPT(t, home)
	c := provider.NewClient(fixtureVersion)
	c.Sleep = noSleep
	return c, s, f, home
}

func chatgptRequest(id string) provider.Request {
	return provider.Request{Role: chatgptRole, Instructions: "policy", CacheID: id, Input: []any{user("hello")}}
}

// TestProviderCacheKey pins where a conversation's cache identity goes for ChatGPT: the body's
// prompt_cache_key (and no prompt_cache_options), and a stable 64-character digest for a longer
// identity. Adapted from kogen-build build/cache_id_test.go.
func TestProviderCacheKey(t *testing.T) {
	c := provider.NewClient(fixtureVersion)
	id := "conversation-0123456789abcdef"
	body := c.Body(chatgptRequest(id))
	if body["prompt_cache_key"] != id {
		t.Fatalf("prompt_cache_key = %v", body["prompt_cache_key"])
	}
	if _, ok := body["prompt_cache_options"]; ok {
		t.Fatal("prompt_cache_options sent")
	}
	if got := c.Body(chatgptRequest(strings.Repeat("c", provider.MaxCacheID)))["prompt_cache_key"]; got != strings.Repeat("c", 64) {
		t.Fatalf("a 64-character identity became %v", got)
	}
	long := c.Body(chatgptRequest(strings.Repeat("c", 100)))["prompt_cache_key"].(string)
	if len(long) != provider.MaxCacheID || long != c.Body(chatgptRequest(strings.Repeat("c", 100)))["prompt_cache_key"] {
		t.Fatalf("a long identity became %q", long)
	}
}

// TestProviderCacheIdentityPerScope pins the identity a Cache keeps for a conversation scope, shared
// through Client.Cache or Request.Cache, and its restore from States. Adapted from kogen-build
// build/cache_id_test.go and build/build.go, kogen-shaping shape/helper_test.go.
func TestProviderCacheIdentityPerScope(t *testing.T) {
	c := provider.NewClient(fixtureVersion)
	c.Cache = provider.NewCache(nil)
	scope := []any{"run-1", "build", 1}
	req := provider.Request{Role: chatgptRole, Instructions: "policy", Input: []any{user("hi")}, Scope: scope}
	first, second := c.Body(req)["prompt_cache_key"], c.Body(req)["prompt_cache_key"]
	if first == nil || first != second {
		t.Fatalf("a conversation changed its identity: %v then %v", first, second)
	}
	other := req
	other.Scope = []any{"run-1", "review", 1}
	if got := c.Body(other)["prompt_cache_key"]; got == first {
		t.Fatalf("two scopes share the identity %v", got)
	}
	states := c.Cache.States()
	if len(states) != 2 {
		t.Fatalf("states %v", states)
	}
	var own *provider.Cache = provider.NewCache(nil)
	req.Cache = own
	if got := c.Body(req)["prompt_cache_key"]; got == first || got != own.Identity(chatgptRole, scope) {
		t.Fatalf("Request.Cache did not hold its own identity: %v", got)
	}
	restored := provider.NewCache(states)
	req.Cache = restored
	if got := c.Body(req)["prompt_cache_key"]; got != first {
		t.Fatalf("a restored cache gave %v, want %v", got, first)
	}
	if !reflect.DeepEqual(restored.States(), states) {
		t.Fatalf("restored states %v, want %v", restored.States(), states)
	}
}

// TestProviderCacheIDFormat pins NewCacheID and MaxCacheID. Adapted from kogen-build
// build/context_external_test.go and build/cache_id_test.go.
func TestProviderCacheIDFormat(t *testing.T) {
	re := regexp.MustCompile(`^conversation-[0-9a-f]{16}$`)
	a, b := provider.NewCacheID(), provider.NewCacheID()
	if !re.MatchString(a) || !re.MatchString(b) || a == b {
		t.Fatalf("%q and %q", a, b)
	}
	if provider.MaxCacheID != 64 || len(a) != 29 {
		t.Fatalf("MaxCacheID %d, identity of %d characters", provider.MaxCacheID, len(a))
	}
}

// TestProviderCacheStates pins the checkpoint form of a conversation's state and its validity.
// Adapted from kogen-build build/legacy.go, build/legacy_test.go and build/unit_test.go.
func TestProviderCacheStates(t *testing.T) {
	st := provider.CacheState{ID: "conversation-0123456789abcdef", Unsupported: true, Response: "resp-1"}
	if got := jsonText(t, st); got != `{"id":"conversation-0123456789abcdef","unsupported":true,"response":"resp-1"}` {
		t.Fatalf("checkpoint form %s", got)
	}
	if got := jsonText(t, provider.CacheState{ID: "x"}); got != `{"id":"x","unsupported":false,"response":null}` {
		t.Fatalf("checkpoint form %s", got)
	}
	var back provider.CacheState
	if err := json.Unmarshal([]byte(`{"id":"x","unsupported":true,"response":"r"}`), &back); err != nil || back.ID != "x" || !back.Unsupported || back.Response != "r" {
		t.Fatalf("%+v, %v", back, err)
	}
	if !st.Valid() || (provider.CacheState{}).Valid() || !(provider.CacheState{ID: strings.Repeat("i", 256)}).Valid() || (provider.CacheState{ID: strings.Repeat("i", 257)}).Valid() {
		t.Fatal("Valid: identities are 1..256 bytes")
	}
	if !provider.ValidCacheStates(map[string]provider.CacheState{"build": st}) || !provider.ValidCacheStates(nil) {
		t.Fatal("valid states refused")
	}
	if provider.ValidCacheStates(map[string]provider.CacheState{"": st}) || provider.ValidCacheStates(map[string]provider.CacheState{"build": {}}) {
		t.Fatal("invalid states accepted")
	}
}

// TestProviderUsageLine pins the progress text of a usage and its sum. Adapted from kogen-shaping
// shape/init_test.go, shape/contract.go and shape/decision.go.
func TestProviderUsageLine(t *testing.T) {
	u := provider.Usage{Input: 100, Cached: 0, Output: 20, Reasoning: 5}
	if got := u.Line(); got != "input=100 cached=0 output=20 reasoning=5" {
		t.Fatalf("Line() = %q", got)
	}
	sum := u.Add(provider.Usage{Input: 1, Cached: 2, Output: 3, Reasoning: 4})
	if sum != (provider.Usage{Input: 101, Cached: 2, Output: 23, Reasoning: 9}) || sum.Line() != "input=101 cached=2 output=23 reasoning=9" {
		t.Fatalf("Add = %+v", sum)
	}
	if sum.Input != 101 || sum.Cached != 2 || sum.Output != 23 || sum.Reasoning != 9 || sum.Total() != 124 {
		t.Fatalf("%+v", sum)
	}
}

// TestProviderResponseBudget pins the response budget: 30 minutes for the package, none for a new
// client, and a refusal of a budget outside 1s..30m before anything is sent. Adapted from kogen
// cli/response_budget_test.go and kogen-executor agent/budget_test.go.
func TestProviderResponseBudget(t *testing.T) {
	if provider.ResponseBudget != 30*time.Minute {
		t.Fatalf("ResponseBudget %s", provider.ResponseBudget)
	}
	c := provider.NewClient(fixtureVersion)
	if c.ResponseBudget != 0 || c.Version != fixtureVersion {
		t.Fatalf("a new client: budget %s, version %q", c.ResponseBudget, c.Version)
	}
	c, s, f, _ := chatgptWorld(t)
	for _, budget := range []time.Duration{time.Second - 1, provider.ResponseBudget + 1, -time.Second} {
		c.ResponseBudget = budget
		_, err := c.Respond(context.Background(), s, chatgptRequest("conversation-0123456789abcdef"), nil)
		e, ok := sys.AsError(err)
		if !ok || e.Class != "provider" || e.Reason != "refused" || e.Detail != "response budget must be zero or between 1s and 30m0s" {
			t.Errorf("budget %s: %v", budget, err)
		}
	}
	if paths, _ := f.seen(); len(paths) != 0 {
		t.Fatalf("a refused budget sent %v", paths)
	}
}

// TestProviderRespondURLSeam pins the request Respond makes to the loopback provider named by
// KOGEN_PROVIDER_URL: POST <url>/v1/responses with the seeded login, the SSE frames consumers' fakes
// write, and the items and usage it returns. Adapted from kogen-build build/helper_test.go and
// kogen-shaping shape/helper_test.go.
func TestProviderRespondURLSeam(t *testing.T) {
	item := callItem("1", "read_file", map[string]any{"path": "a"})
	c, s, f, _ := chatgptWorld(t, sse(textItem("hello back"), item))
	rec := &attempts{}
	var observer provider.Observer = rec
	req := chatgptRequest("conversation-0123456789abcdef")
	req.Context = map[string]any{"phase": "build", "slug": "k-contract"}
	req.Tools = []any{map[string]any{"type": "function", "name": "read_file", "parameters": map[string]any{"type": "object"}}}
	resp, err := c.Respond(context.Background(), s, req, observer)
	if err != nil {
		t.Fatal(err)
	}
	paths, bodies := f.seen()
	if !reflect.DeepEqual(paths, []string{"/v1/responses"}) {
		t.Fatalf("paths %v", paths)
	}
	if got := f.heads[0].Get("Authorization"); got != "Bearer fake-access-token" {
		t.Fatalf("Authorization %q", got)
	}
	sent := f.request(t, 0)
	if sent["model"] != "gpt-6.1-sol" || sent["instructions"] != "policy" || sent["prompt_cache_key"] != "conversation-0123456789abcdef" || len(sent["tools"].([]any)) != 1 {
		t.Fatalf("request body %s", bodies[0])
	}
	if len(resp.Items) != 2 || resp.Items[0]["type"] != "message" || resp.Items[1]["call_id"] != "call-1" || resp.Items[1]["name"] != "read_file" {
		t.Fatalf("items %v", resp.Items)
	}
	if resp.Usage != (provider.Usage{Input: 11, Cached: 3, Output: 7, Reasoning: 2}) {
		t.Fatalf("usage %+v", resp.Usage)
	}
	k := resp.Known
	if k.Input == nil || *k.Input != 11 || k.Cached == nil || *k.Cached != 3 || k.Output == nil || *k.Output != 7 || k.Reasoning == nil || *k.Reasoning != 2 || k.Write != nil {
		t.Fatalf("known usage %+v", k)
	}
	if got := jsonText(t, k.Map()); got != `{"cached":3,"input":11,"output":7,"reasoning":2,"write":null,"write_12h":null,"write_30m":null}` {
		t.Fatalf("KnownUsage.Map = %s", got)
	}
	if !strings.HasPrefix(resp.OperationID, "operation-") || resp.Model != "" {
		t.Fatalf("operation %q, model %q", resp.OperationID, resp.Model)
	}
	records := rec.records()
	if len(records) != 1 || records[0]["phase"] != "build" || records[0]["slug"] != "k-contract" || records[0]["conversation_id"] != "conversation-0123456789abcdef" {
		t.Fatalf("attempt records %v", records)
	}
}

// TestProviderRespondFailures pins the failures of a request that cannot be sent or is refused: a refusal
// is a provider failure that is not retried, an unknown provider and a missing session are errors.
// Adapted from kogen-build build/helper_test.go (its fake refuses with 400) and kogen cli/compatible_login_test.go.
func TestProviderRespondFailures(t *testing.T) {
	c, s, f, _ := chatgptWorld(t, refusal)
	_, err := c.Respond(context.Background(), s, chatgptRequest("conversation-0123456789abcdef"), nil)
	e, ok := sys.AsError(err)
	if !ok || e.Class != "provider" || e.Exit != 4 {
		t.Fatalf("err %v", err)
	}
	if paths, _ := f.seen(); len(paths) != 1 {
		t.Fatalf("a refusal is not retried: %v", paths)
	}
	if _, err := c.Respond(context.Background(), s, provider.Request{Role: provider.Role{Provider: "nobody", Model: "m"}, Input: []any{user("x")}}, nil); err == nil || !strings.Contains(err.Error(), "unknown provider nobody") {
		t.Fatalf("unknown provider: %v", err)
	}
	if _, err := c.Respond(context.Background(), nil, chatgptRequest("conversation-0123456789abcdef"), nil); err == nil {
		t.Fatal("a request without a session was sent")
	}
}

// TestProviderRespondSingle pins Request.Single: one attempt for ChatGPT, no retry of a transient
// failure, where the same request without Single retries it. Adapted from kogen-shaping shape/batch.go.
func TestProviderRespondSingle(t *testing.T) {
	overloaded := func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(503)
		io.WriteString(w, `{"error":{"code":"server_error","message":"overloaded","type":"server_error"}}`)
	}
	c, s, f, _ := chatgptWorld(t, overloaded, overloaded, sse(textItem("late")))
	req := chatgptRequest("conversation-0123456789abcdef")
	req.Single = true
	_, err := c.Respond(context.Background(), s, req, nil)
	e, ok := sys.AsError(err)
	if !ok || e.Class != "provider" || e.Reason != "unavailable" || e.Exit != 4 {
		t.Fatalf("single attempt: %v", err)
	}
	if paths, _ := f.seen(); len(paths) != 1 {
		t.Fatalf("Single sent %v", paths)
	}
	req.Single = false
	resp, err := c.Respond(context.Background(), s, req, nil)
	if err != nil || len(resp.Items) != 1 {
		t.Fatalf("retrying request: %v", err)
	}
	if paths, _ := f.seen(); len(paths) != 3 {
		t.Fatalf("the retry made %v", paths)
	}
}

// TestProviderRespondCredentialsFile pins the login a consumer seeds: $HOME/.kogen/credentials/chatgpt.json
// (mode 0600, in a 0700 .kogen) with client_id oaiapp_fake, access_token, refresh_token, a future
// expires_at, scope and email is usable, and a file without a usable access_token is not. Adapted from
// kogen-build build/helper_test.go.
func TestProviderRespondCredentialsFile(t *testing.T) {
	c, s, f, home := chatgptWorld(t, sse(textItem("hi")), sse(textItem("hi")))
	for path, mode := range map[string]os.FileMode{
		filepath.Join(home, ".kogen"):                                0o700,
		filepath.Join(home, ".kogen", "credentials", "chatgpt.json"): 0o600,
	} {
		if st, err := os.Stat(path); err != nil || st.Mode().Perm() != mode {
			t.Fatalf("%s: %v, %v", path, st, err)
		}
	}
	var saved map[string]any
	raw, _ := os.ReadFile(filepath.Join(home, ".kogen", "credentials", "chatgpt.json"))
	if err := json.Unmarshal(raw, &saved); err != nil || saved["client_id"] != "oaiapp_fake" || saved["access_token"] != "fake-access-token" || saved["email"] != "integration@example.invalid" {
		t.Fatalf("seeded login %s", raw)
	}
	if err := provider.RequireLogin(home, []provider.Role{chatgptRole}); err != nil {
		t.Fatalf("RequireLogin: %v", err)
	}
	if got := provider.Status(home); len(got) != 4 || got[0] != "chatgpt: signed in (integration@example.invalid)" || got[1] != "supergrok: not signed in" {
		t.Fatalf("Status = %q", got)
	}
	if _, err := c.Respond(context.Background(), s, chatgptRequest("conversation-0123456789abcdef"), nil); err != nil {
		t.Fatalf("the seeded login was not usable: %v", err)
	}
	if got := f.heads[0].Get("Authorization"); got != "Bearer fake-access-token" {
		t.Fatalf("Authorization %q", got)
	}

	delete(saved, "access_token")
	writeFile(t, filepath.Join(home, ".kogen", "credentials", "chatgpt.json"), jsonText(t, saved), 0o600)
	before := responsesSeen(f)
	if _, err := c.Respond(context.Background(), s, chatgptRequest("conversation-0123456789abcdef"), nil); err == nil {
		t.Fatal("a login without an access token was used")
	}
	if after := responsesSeen(f); after != before {
		t.Fatalf("a login without an access token sent %d requests", after-before)
	}
}

// responsesSeen is the number of /v1/responses requests the provider saw.
func responsesSeen(f *fakeProvider) int {
	paths, _ := f.seen()
	n := 0
	for _, p := range paths {
		if p == "/v1/responses" {
			n++
		}
	}
	return n
}

// TestProviderRespondWithoutALoginSendsNothing pins the refusal of a request with no usable login and
// of RequireLogin before any request. Adapted from kogen-shaping shape/init.go and kogen-build build/builder.go.
func TestProviderRespondWithoutALoginSendsNothing(t *testing.T) {
	f := newFakeProvider(t, sse(textItem("never")))
	s, _, home := newSession(t, f.env()...)
	c := provider.NewClient(fixtureVersion)
	c.Sleep = noSleep
	err := provider.RequireLogin(home, []provider.Role{chatgptRole, {Provider: "anthropic", Model: "m"}})
	e, ok := sys.AsError(err)
	if !ok || e.Class != "provider" || e.Reason != "login" || e.Exit != 4 {
		t.Fatalf("RequireLogin = %v", err)
	}
	if _, err := c.Respond(context.Background(), s, chatgptRequest("conversation-0123456789abcdef"), nil); err == nil {
		t.Fatal("a request without a login succeeded")
	} else if e, ok := sys.AsError(err); !ok || e.Class != "provider" {
		t.Fatalf("err %v", err)
	}
	if paths, _ := f.seen(); len(paths) != 0 {
		t.Fatalf("sent %v", paths)
	}
	if got := provider.Status(home); got[0] != "chatgpt: not signed in" {
		t.Fatalf("Status = %q", got)
	}
}

// TestProviderRespondWaitText pins the failure when the response budget runs out: provider/unavailable,
// exit 4, detail `<Label> response wait exceeded <budget>`, driven by the Now and Sleep seams so no
// real time passes. Adapted from kogen-executor agent/budget_test.go.
func TestProviderRespondWaitText(t *testing.T) {
	for _, c := range []struct {
		budget time.Duration
		text   string
	}{{10 * time.Minute, "ChatGPT response wait exceeded 10m0s"}, {0, "ChatGPT response wait exceeded 30 minutes"}} {
		var mu sync.Mutex
		now := time.Now()
		stall := func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "text/event-stream")
			w.WriteHeader(http.StatusOK)
			w.(http.Flusher).Flush()
			mu.Lock()
			now = now.Add(30*time.Minute + time.Second)
			mu.Unlock()
			panic(http.ErrAbortHandler)
		}
		client, s, f, _ := chatgptWorld(t, stall, stall, stall, stall)
		client.Now = func() time.Time { mu.Lock(); defer mu.Unlock(); return now }
		client.ResponseBudget = c.budget
		start := time.Now()
		_, err := client.Respond(context.Background(), s, chatgptRequest("conversation-0123456789abcdef"), nil)
		e, ok := sys.AsError(err)
		if !ok || e.Class != "provider" || e.Reason != "unavailable" || e.Exit != 4 || e.Detail != c.text {
			t.Fatalf("budget %s: %v", c.budget, err)
		}
		if time.Since(start) > 20*time.Second {
			t.Fatalf("real time passed: %s", time.Since(start))
		}
		if paths, _ := f.seen(); len(paths) == 0 {
			t.Fatal("nothing was sent")
		}
	}
}

// TestProviderToolChoice pins the forced tool of a request: where the route supports it the body names the
// tool, where it does not the request is refused before sending. Adapted from kogen-shaping shape/force.go
// and kogen-build build/k_reviewretry_safety_test.go.
func TestProviderToolChoice(t *testing.T) {
	tools := []any{map[string]any{"type": "function", "name": "finish", "parameters": map[string]any{"type": "object"}}}
	req := chatgptRequest("conversation-0123456789abcdef")
	req.Tools, req.ToolChoice = tools, "finish"
	c := provider.NewClient(fixtureVersion)
	if !provider.SupportsToolChoice(req.Role) {
		t.Fatal("ChatGPT cannot force a tool")
	}
	if got := jsonText(t, c.Body(req)["tool_choice"]); got != `{"name":"finish","type":"function"}` {
		t.Fatalf("tool_choice %s", got)
	}
	req.ToolChoice = ""
	if _, forced := c.Body(req)["tool_choice"].(map[string]any); forced {
		t.Fatal("a tool is forced without a ToolChoice")
	}
	anthropic := provider.Role{Provider: "anthropic", Model: "claude-sonnet-5-5", Effort: "high"}
	if provider.SupportsToolChoice(anthropic) || provider.SupportsToolChoice(provider.Role{Provider: "nobody", Model: "m"}) {
		t.Fatal("a route that cannot force a tool says it can")
	}
	f := newFakeProvider(t)
	s, _, home := newSession(t, f.env()...)
	seedKey(t, home, "anthropic", "sk-ant-FIXTURE-KEY")
	_, err := c.Respond(context.Background(), s, provider.Request{Role: anthropic, Instructions: "p", Input: []any{user("hi")}, Tools: tools, ToolChoice: "finish", CacheID: "x"}, nil)
	e, ok := sys.AsError(err)
	if !ok || e.Class != "provider" || e.Reason != "unsupported_capability" {
		t.Fatalf("err %v", err)
	}
	if paths, _ := f.seen(); len(paths) != 0 {
		t.Fatalf("sent %v", paths)
	}
}

// TestProviderRoleSelectsTheProvider pins Role, Name, Lookup and Info.Name. Adapted from kogen
// cli/readiness/readiness.go and kogen-build build/review.go, build/state.go.
func TestProviderRoleSelectsTheProvider(t *testing.T) {
	role := provider.Role{Provider: "anthropic", Model: "claude-sonnet-5-5", Effort: "high", BaseURL: ""}
	if role.Provider != "anthropic" || role.Model != "claude-sonnet-5-5" || role.Effort != "high" || role.BaseURL != "" {
		t.Fatalf("%+v", role)
	}
	if provider.Name(role) != "anthropic" || provider.Name(provider.Role{}) != "chatgpt" {
		t.Fatalf("names %q %q", provider.Name(role), provider.Name(provider.Role{}))
	}
	if info, ok := provider.Lookup(""); !ok || info.Name != "chatgpt" {
		t.Fatalf("Lookup(\"\") = %+v, %v", info, ok)
	}
	if info, ok := provider.Lookup("openai-compatible"); !ok || info.Name != "openai-compatible" {
		t.Fatalf("Lookup(openai-compatible) = %+v, %v", info, ok)
	}
	if info, ok := provider.Lookup("nobody"); ok || info.Name != "" {
		t.Fatalf("Lookup(nobody) = %+v, %v", info, ok)
	}
	if text := provider.OfficialText(); !strings.HasPrefix(text, "Official compatibility") || !strings.Contains(text, "chatgpt/gpt-6.1-sol") {
		t.Fatalf("OfficialText %.200q", text)
	}
	if p := provider.Profiles(); p.SchemaVersion != 1 || len(p.Profiles) == 0 {
		t.Fatalf("Profiles %+v", p.SchemaVersion)
	}
}

// TestProviderSeamsMustBeLoopback pins CheckSeams: the loopback http origins pass, anything else is
// environment/invalid_test_seam with exit 3. Adapted from kogen cli/native.go.
func TestProviderSeamsMustBeLoopback(t *testing.T) {
	for _, ok := range []string{"http://127.0.0.1:4010", "http://localhost:4010"} {
		if err := provider.CheckSeams(sys.NewWith([]string{"KOGEN_PROVIDER_URL=" + ok, "KOGEN_AUTH_URL=" + ok}, "/")); err != nil {
			t.Errorf("%s: %v", ok, err)
		}
	}
	if err := provider.CheckSeams(sys.NewWith(nil, "/")); err != nil {
		t.Errorf("no seams: %v", err)
	}
	for _, bad := range []string{"http://example.invalid", "https://127.0.0.1:4010", "http://127.0.0.1"} {
		err := provider.CheckSeams(sys.NewWith([]string{"KOGEN_AUTH_URL=" + bad}, "/"))
		e, isErr := sys.AsError(err)
		if !isErr || e.Class != "environment" || e.Reason != "invalid_test_seam" || e.Exit != 3 {
			t.Errorf("%s: %v", bad, err)
		}
	}
}

// TestProviderContractBlocksAndFingerprint pins the two blocks of a contract message and the evidence of
// a value. Adapted from kogen-shaping shape/context.go, kogen-build build/material_test.go and build/builder.go.
func TestProviderContractBlocksAndFingerprint(t *testing.T) {
	want := []any{map[string]any{"type": "input_text", "text": "stable"}, map[string]any{"type": "input_text", "text": "dynamic"}}
	if got := provider.ContractBlocks("stable", "dynamic"); !reflect.DeepEqual(got, want) {
		t.Fatalf("ContractBlocks = %v", got)
	}
	d := provider.Fingerprint("abc")
	if d == nil || d.SHA256 != "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" || d.Bytes != 3 {
		t.Fatalf("Fingerprint(abc) = %+v", d)
	}
	if provider.Fingerprint(nil) != nil {
		t.Fatal("Fingerprint(nil) is not nil")
	}
	a := provider.Fingerprint(map[string]any{"b": 1, "a": 2})
	if b := provider.Fingerprint(map[string]any{"a": 2, "b": 1}); a == nil || *a != *b || a.Bytes != len(`{"a":2,"b":1}`) {
		t.Fatalf("Fingerprint of an object: %+v", a)
	}
}

// TestProviderKnownUsage pins the analytical usage: nil unless reported, with its record form.
// Adapted from kogen-build build/records_test.go and kogen-shaping shape/evidence.go.
func TestProviderKnownUsage(t *testing.T) {
	n := func(v int) *int { return &v }
	k := provider.KnownUsage{Input: n(10), Cached: n(4), Write: n(2), Output: n(6), Reasoning: n(1)}
	if *k.Input != 10 || *k.Cached != 4 || *k.Write != 2 || *k.Output != 6 || *k.Reasoning != 1 {
		t.Fatalf("%+v", k)
	}
	want := map[string]any{"input": 10, "cached": 4, "write": 2, "write_30m": nil, "write_12h": nil, "output": 6, "reasoning": 1}
	if got := k.Map(); !reflect.DeepEqual(got, want) {
		t.Fatalf("Map = %v", got)
	}
	if got := (provider.KnownUsage{}).Map(); got["input"] != nil || len(got) != 7 {
		t.Fatalf("Map of nothing = %v", got)
	}
}

// compatibleTransport answers every request with a Chat Completions success and keeps what it saw.
type compatibleTransport struct {
	mu   sync.Mutex
	reqs []*http.Request
}

func (r *compatibleTransport) RoundTrip(q *http.Request) (*http.Response, error) {
	r.mu.Lock()
	r.reqs = append(r.reqs, q)
	r.mu.Unlock()
	body := `{"id":"chatcmpl-fixture","model":"m","choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}`
	return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": {"application/json"}}, Body: io.NopCloser(strings.NewReader(body)), Request: q}, nil
}

// TestProviderLoginWithBaseURLBindsTheKeyToItsOrigin pins LoginWithBaseURL and Client.HTTP: the key is
// saved with its origin (mode 0600), sent only there, and a role at another origin is refused before any
// request. Adapted from kogen cli/compatible_login_test.go.
func TestProviderLoginWithBaseURLBindsTheKeyToItsOrigin(t *testing.T) {
	s, _, home := newSession(t)
	var out strings.Builder
	s.Stdout = &out
	c := provider.NewClient(fixtureVersion)
	c.Sleep = noSleep
	c.Input = &provider.Input{Reader: strings.NewReader("KEY\n")}
	if err := c.LoginWithBaseURL(context.Background(), s, "openai-compatible", "https://a.example.invalid/v1", nil); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(home, ".kogen", "credentials", "openai-compatible.json")
	raw, err := os.ReadFile(path)
	var saved map[string]any
	if err != nil || json.Unmarshal(raw, &saved) != nil || len(saved) != 3 || saved["provider"] != "openai-compatible" || saved["api_key"] != "KEY" || saved["origin"] != "https://a.example.invalid" {
		t.Fatalf("saved credential %s, %v", raw, err)
	}
	if st, _ := os.Stat(path); st.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", st.Mode())
	}
	if out.String() != "openai-compatible: key saved (not verified)\n" {
		t.Fatalf("stdout %q", out.String())
	}

	rt := &compatibleTransport{}
	c.HTTP = &http.Client{Transport: rt}
	role := provider.Role{Provider: "openai-compatible", Model: "m", Effort: "default", BaseURL: "https://a.example.invalid/v1"}
	req := provider.Request{Role: role, Instructions: "policy", Input: []any{user("hi")}, Scope: "s"}
	if _, err := c.Respond(context.Background(), s, req, nil); err != nil {
		t.Fatal(err)
	}
	if len(rt.reqs) != 1 || rt.reqs[0].URL.String() != "https://a.example.invalid/v1/chat/completions" || rt.reqs[0].Header.Get("Authorization") != "Bearer KEY" {
		t.Fatalf("requests %v", rt.reqs)
	}
	req.Role.BaseURL = "https://b.example.invalid/v1"
	_, err = c.Respond(context.Background(), s, req, nil)
	e, ok := sys.AsError(err)
	if !ok || e.Class != "provider" || e.Reason != "refused" || !strings.Contains(e.Detail, "belongs to https://a.example.invalid but this request goes to https://b.example.invalid") {
		t.Fatalf("another origin: %v", err)
	}
	if len(rt.reqs) != 1 || strings.Contains(e.Render(), "KEY") {
		t.Fatalf("%d requests, error %q", len(rt.reqs), e.Render())
	}

	// A URL the login refuses keeps the saved login byte for byte.
	for _, bad := range []string{"http://a.example.invalid/v1", "", "not a url"} {
		c.Input = &provider.Input{Reader: strings.NewReader("OTHER\n")}
		err := c.LoginWithBaseURL(context.Background(), s, "openai-compatible", bad, nil)
		e, ok := sys.AsError(err)
		if !ok || e.Class != "provider" || e.Reason != "login_failed" || e.Exit != 4 {
			t.Errorf("%q: %v", bad, err)
		}
		if after, _ := os.ReadFile(path); string(after) != string(raw) {
			t.Errorf("%q changed the saved login", bad)
		}
	}
	c.Input = &provider.Input{Reader: strings.NewReader("OTHER\n")}
	if err := c.Login(context.Background(), s, "openai-compatible", nil); err == nil {
		t.Error("Login without a URL saved an unbound key")
	}
}

// TestProviderLoginSavesKeysAndTokens pins Login for the key providers and the Claude Code token, reading
// Client.Input, without calling the redirect. Adapted from kogen cli/native.go.
func TestProviderLoginSavesKeysAndTokens(t *testing.T) {
	s, _, home := newSession(t)
	var out strings.Builder
	s.Stdout = &out
	c := provider.NewClient(fixtureVersion)
	c.Sleep = noSleep
	var redirect provider.RedirectFunc = func(authURL string) (url.Values, error) {
		t.Error("a key login asked for a browser redirect")
		return nil, errors.New("unused")
	}
	c.Input = &provider.Input{Reader: strings.NewReader("sk-ant-FIXTURE-KEY\n")}
	if err := c.Login(context.Background(), s, "anthropic", redirect); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join(home, ".kogen", "credentials", "anthropic.json"))
	var saved map[string]any
	if err != nil || json.Unmarshal(raw, &saved) != nil || saved["provider"] != "anthropic" || saved["api_key"] != "sk-ant-FIXTURE-KEY" {
		t.Fatalf("saved %s, %v", raw, err)
	}
	if err := provider.RequireLogin(home, []provider.Role{{Provider: "anthropic", Model: "claude-sonnet-5-5"}}); err != nil {
		t.Fatalf("RequireLogin after login: %v", err)
	}
	if token, ok := provider.ClaudeCodeToken(home); ok || token != "" {
		t.Fatalf("a token before login: %q", token)
	}
	c.Input = &provider.Input{Reader: strings.NewReader("tok_en-1.2\n")}
	if err := c.Login(context.Background(), s, provider.ClaudeCodeName, nil); err != nil {
		t.Fatal(err)
	}
	if token, ok := provider.ClaudeCodeToken(home); !ok || token != "tok_en-1.2" {
		t.Fatalf("token %q, %v", token, ok)
	}
	if out.String() != "anthropic: key saved (not verified)\nclaude-code: token saved (not verified)\n" {
		t.Fatalf("stdout %q", out.String())
	}
	c.Input = &provider.Input{Reader: strings.NewReader("two words\n")}
	err = c.Login(context.Background(), s, provider.ClaudeCodeName, nil)
	if e, ok := sys.AsError(err); !ok || e.Reason != "login_failed" || strings.Contains(e.Render(), "two words") {
		t.Fatalf("an invalid token: %v", err)
	}
	if token, _ := provider.ClaudeCodeToken(home); token != "tok_en-1.2" {
		t.Fatalf("a refused login changed the token to %q", token)
	}
	if err := c.Login(context.Background(), s, "nobody", nil); err == nil {
		t.Fatal("an unknown provider logged in")
	}
	if in := provider.StdinInput(); in.Reader != os.Stdin {
		t.Fatalf("StdinInput reads %v", in.Reader)
	}
}

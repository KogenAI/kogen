package consumes

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/KogenAI/kogen-loop/provider"
	"github.com/KogenAI/kogen-loop/sys"
)

// Signatures kogen's callers use: cli/native.go and cli/readiness/readiness.go.
var (
	_ func(string) (provider.Info, bool)                                                                 = provider.Lookup
	_ func(string, []provider.Role) error                                                                = provider.RequireLogin
	_ func(string) []string                                                                              = provider.Status
	_ func(string) (string, bool)                                                                        = provider.ClaudeCodeToken
	_ func() string                                                                                      = provider.OfficialText
	_ func() provider.ProfileCatalog                                                                     = provider.Profiles
	_ func() provider.Input                                                                              = provider.StdinInput
	_ func(*sys.Session) error                                                                           = provider.CheckSeams
	_ func(string) *provider.Client                                                                      = provider.NewClient
	_ provider.RedirectFunc                                                                              = func(string) (url.Values, error) { return nil, nil }
	_ func(*provider.Client) *provider.Input                                                             = func(c *provider.Client) *provider.Input { return c.Input }
	_ func(*provider.Client, context.Context, *sys.Session, string, provider.RedirectFunc) error         = (*provider.Client).Login
	_ func(*provider.Client, context.Context, *sys.Session, string, string, provider.RedirectFunc) error = (*provider.Client).LoginWithBaseURL
)

// TestLookupFindsTheProvidersKogenKnows: Lookup gives the Info of a provider name, whose Name is
// the name, with "" meaning ChatGPT (a role without a provider), and reports an unknown name.
func TestLookupFindsTheProvidersKogenKnows(t *testing.T) {
	for _, name := range []string{"chatgpt", "supergrok", "opencode-go", "anthropic", "openai-compatible"} {
		info, ok := provider.Lookup(name)
		if !ok || info.Name != name {
			t.Fatalf("Lookup(%q) = %q, %v", name, info.Name, ok)
		}
	}
	if info, ok := provider.Lookup(""); !ok || info.Name != "chatgpt" {
		t.Fatalf(`Lookup("") = %q, %v, want chatgpt`, info.Name, ok)
	}
	if _, ok := provider.Lookup("no-such-provider"); ok {
		t.Fatalf("Lookup found a provider that does not exist")
	}
}

// TestProfilesIsTheOfflineCatalogKogenPrintsAsJSON: `kogen provider list --json` encodes the
// value of Profiles: an object with a schema version and a nonempty list of profiles, each with
// its id, provider, model, route, limits, settings, documented efforts, qualifications and
// evidence.
func TestProfilesIsTheOfflineCatalogKogenPrintsAsJSON(t *testing.T) {
	raw, err := json.Marshal(provider.Profiles())
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]json.RawMessage
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	if _, ok := doc["schema_version"]; !ok {
		t.Fatalf("no schema_version in %s", raw)
	}
	var profiles []map[string]json.RawMessage
	if err := json.Unmarshal(doc["profiles"], &profiles); err != nil || len(profiles) == 0 {
		t.Fatalf("profiles = %s (%v)", doc["profiles"], err)
	}
	for _, p := range profiles {
		for _, key := range []string{"id", "provider", "model", "route", "limits", "settings", "documented_efforts", "qualifications", "evidence"} {
			if _, ok := p[key]; !ok {
				t.Fatalf("profile %s has no %q", p["id"], key)
			}
		}
	}
}

// TestOfficialTextIsTheCompatibilityTextOfTheProviderList: OfficialText ends the plain
// `kogen provider list`: a heading, one `id: provider/model — route` line for each profile of
// Profiles, and the closing notes, every line ending in a newline.
func TestOfficialTextIsTheCompatibilityTextOfTheProviderList(t *testing.T) {
	text := provider.OfficialText()
	if !strings.HasPrefix(text, "Official compatibility (text/tool input, normal routes only):\n") || !strings.HasSuffix(text, "\n") {
		t.Fatalf("OfficialText = %q", text)
	}
	raw, _ := json.Marshal(provider.Profiles())
	var doc struct {
		Profiles []struct{ ID, Provider, Model, Route string } `json:"profiles"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil || len(doc.Profiles) == 0 {
		t.Fatalf("profiles: %v", err)
	}
	for _, p := range doc.Profiles {
		line := fmt.Sprintf("%s: %s/%s — %s\n", p.ID, p.Provider, p.Model, p.Route)
		if !strings.Contains(text, "\n"+line) {
			t.Fatalf("OfficialText has no line %q:\n%s", line, text)
		}
	}
	if !strings.Contains(text, "Recommended ChatGPT defaults:") || !strings.Contains(text, "are not qualification.") {
		t.Fatalf("OfficialText lacks its closing notes:\n%s", text)
	}
}

// TestStatusListsTheLocalLoginsInCatalogOrder: Status is the offline login list of `kogen
// provider list`: one `name: state` line per provider in catalog order, `not signed in` when
// nothing is saved, openai-compatible only once a key is saved, and the Claude Code token last.
func TestStatusListsTheLocalLoginsInCatalogOrder(t *testing.T) {
	home := t.TempDir()
	want := []string{"chatgpt: not signed in", "supergrok: not signed in", "opencode-go: not signed in", "anthropic: not signed in"}
	if got := provider.Status(home); !slices.Equal(got, want) {
		t.Fatalf("Status of an empty home = %q, want %q", got, want)
	}
	writeFile(t, credentialsFile(home, "chatgpt"), fmt.Sprintf(`{"client_id":"oaiapp_fixture","access_token":"a","refresh_token":"r","expires_at":%d,"email":"user@example.invalid"}`, time.Now().Unix()+3600))
	writeFile(t, credentialsFile(home, "supergrok"), fmt.Sprintf(`{"client_id":"fixture","referrer":"kogen","access_token":"a","refresh_token":"r","expires_at":%d}`, time.Now().Unix()+3600))
	writeFile(t, credentialsFile(home, "opencode-go"), `{"provider":"opencode-go","api_key":"fixture-key"}`)
	writeFile(t, credentialsFile(home, "anthropic"), `{"provider":"anthropic","api_key":"fixture-key"}`)
	writeFile(t, credentialsFile(home, "openai-compatible"), `{"provider":"openai-compatible","api_key":"fixture-key","origin":"https://llm.example.invalid"}`)
	writeFile(t, credentialsFile(home, "claude-code"), `{"provider":"claude-code","api_key":"fixture-token.1"}`)
	want = []string{
		"chatgpt: signed in (user@example.invalid)", "supergrok: signed in", "opencode-go: key saved (not verified)",
		"anthropic: key saved (not verified)", "openai-compatible: key saved (not verified)", "claude-code: token saved (not verified)",
	}
	if got := provider.Status(home); !slices.Equal(got, want) {
		t.Fatalf("Status = %q, want %q", got, want)
	}
}

// TestStatusSaysWhenASavedLoginCannotBeUsed: a login file that is not a usable login is
// reported with the command that fixes it, and a key file that is not one reads as no login.
func TestStatusSaysWhenASavedLoginCannotBeUsed(t *testing.T) {
	home := t.TempDir()
	writeFile(t, credentialsFile(home, "chatgpt"), `{"client_id":"not-an-app"}`)
	writeFile(t, credentialsFile(home, "anthropic"), `{"provider":"anthropic","api_key":"   "}`)
	got := provider.Status(home)
	if got[0] != "chatgpt: saved login cannot be used; run kogen provider login chatgpt" || got[3] != "anthropic: not signed in" {
		t.Fatalf("Status = %q", got)
	}
}

// TestClaudeCodeTokenIsTheSavedTokenOrNone: the token of the saved Claude Code login, with
// true; none when no file is saved or the file holds no usable token (readiness and the
// provider list only ask whether one is saved).
func TestClaudeCodeTokenIsTheSavedTokenOrNone(t *testing.T) {
	home := t.TempDir()
	if tok, ok := provider.ClaudeCodeToken(home); ok || tok != "" {
		t.Fatalf("token of an empty home = %q, %v", tok, ok)
	}
	writeFile(t, credentialsFile(home, "claude-code"), `{"provider":"claude-code","api_key":"two words"}`)
	if tok, ok := provider.ClaudeCodeToken(home); ok || tok != "" {
		t.Fatalf("token of an unusable file = %q, %v", tok, ok)
	}
	writeFile(t, credentialsFile(home, "claude-code"), `{"provider":"claude-code","api_key":"fixture.token_1-x"}`)
	if tok, ok := provider.ClaudeCodeToken(home); !ok || tok != "fixture.token_1-x" {
		t.Fatalf("token = %q, %v", tok, ok)
	}
}

// TestRequireLoginRefusesARoleWithoutAStoredLogin: readiness asks RequireLogin(home, roles of the
// provider each configured role uses): nil when every used provider has a usable login, otherwise
// a provider/login *sys.Error, exit 4, naming `kogen provider login <provider>`. Only the
// providers of the roles are checked, an empty provider is ChatGPT, and a key that is optional
// (openai-compatible) needs none.
func TestRequireLoginRefusesARoleWithoutAStoredLogin(t *testing.T) {
	home := t.TempDir()
	role := func(name string) []provider.Role { return []provider.Role{{Provider: name}} }
	if err := provider.RequireLogin(home, nil); err != nil {
		t.Fatalf("no roles: %v", err)
	}
	if err := provider.RequireLogin(home, role("openai-compatible")); err != nil {
		t.Fatalf("keyless openai-compatible: %v", err)
	}
	wantFailure(t, provider.RequireLogin(home, role("")), 4, "provider/login: not signed in; run kogen provider login chatgpt\n")
	wantFailure(t, provider.RequireLogin(home, role("chatgpt")), 4, "provider/login: not signed in; run kogen provider login chatgpt\n")
	wantFailure(t, provider.RequireLogin(home, role("opencode-go")), 4, "provider/login: no usable OpenCode Go key; run kogen provider login opencode-go\n")
	wantFailure(t, provider.RequireLogin(home, role("anthropic")), 4, "provider/login: no usable Anthropic key; run kogen provider login anthropic\n")

	writeFile(t, credentialsFile(home, "anthropic"), `{"provider":"anthropic","api_key":"fixture-key"}`)
	writeFile(t, credentialsFile(home, "chatgpt"), fmt.Sprintf(`{"client_id":"oaiapp_fixture","access_token":"a","refresh_token":"r","expires_at":%d}`, time.Now().Unix()+3600))
	if err := provider.RequireLogin(home, []provider.Role{{Provider: "anthropic"}, {Provider: ""}}); err != nil {
		t.Fatalf("saved logins: %v", err)
	}
	wantFailure(t, provider.RequireLogin(home, []provider.Role{{Provider: "anthropic"}, {Provider: "opencode-go"}}), 4,
		"provider/login: no usable OpenCode Go key; run kogen provider login opencode-go\n")
	if _, err := os.Stat(filepath.Join(home, ".kogen", "host-id")); err == nil {
		t.Fatalf("RequireLogin wrote a file")
	}
}

package provider

import (
	"encoding/json"
	"strings"
	"testing"

	"kogen-loop/sys"
)

func TestExactProfileQualification(t *testing.T) {
	for _, tc := range []struct{ role, provider, model, effort, status, profile string }{
		{"shape", "chatgpt", "gpt-6.1-sol", "high", "supported", "chatgpt-sol-6-1"},
		{"build", "chatgpt", "gpt-6.1-sol", "medium", "supported", "chatgpt-sol-6-1"},
		{"review", "chatgpt", "gpt-6.1-sol", "high", "supported", "chatgpt-sol-6-1"},
		{"review", "anthropic", "claude-sonnet-5-5", "medium", "supported", "anthropic-sonnet-5-5"},
		{"review", "chatgpt", "gpt-6.1-sol", "medium", "experimental", "chatgpt-sol-6-1"},
		{"build", "chatgpt", "gpt-6.1-sol", "arbitrary", "experimental", "chatgpt-sol-6-1"},
		{"worker", "chatgpt", "gpt-6.1-sol", "high", "experimental", "chatgpt-sol-6-1"},
		{"", "chatgpt", "gpt-6.1-sol", "high", "experimental", "chatgpt-sol-6-1"},
		{"shape", "chatgpt", "gpt-6.1-sol-next", "high", "experimental", ""},
		{"shape", "openai-compatible", "gpt-6.1-sol", "high", "experimental", ""},
	} {
		req := Request{Role: Role{Provider: tc.provider, Model: tc.model, Effort: tc.effort}, Context: map[string]any{"role": tc.role}}
		c := Classify(req, &sys.Session{})
		profile := ""
		if c.Profile != nil {
			profile = *c.Profile
		}
		if c.Status != tc.status || profile != tc.profile || c.Role != tc.role || c.Effort != tc.effort {
			t.Fatalf("%+v: %+v", tc, c)
		}
	}
	req := Request{Role: Role{Model: "gpt-6.1-sol", Effort: "high"}, Context: map[string]any{"role": "shape"}}
	for _, name := range []string{"KOGEN_PROVIDER_URL", "KOGEN_AUTH_URL"} {
		if c := Classify(req, &sys.Session{Env: []string{name + "=http://127.0.0.1:1234"}}); c.Status != "experimental" {
			t.Fatal(c)
		}
	}
	req.Input = []any{map[string]any{"type": "input_image"}}
	if c := Classify(req, &sys.Session{}); c.Status != "experimental" {
		t.Fatal(c)
	}
}

func TestUsableFamilyBound(t *testing.T) {
	ptr := func(n int) *int { return &n }
	for _, tc := range []struct {
		name   string
		limits Limits
		want   int
	}{
		{"unknown", Limits{}, 524288},
		{"input smaller", Limits{Input: ptr(100), Reserve: 131072}, 100},
		{"context smaller", Limits{Context: ptr(131172)}, 100},
		{"input minimum", Limits{Input: ptr(99), Context: ptr(131172), Reserve: 131072}, 99},
		{"context minimum", Limits{Input: ptr(101), Context: ptr(131172), Reserve: 131072}, 100},
		{"global minimum", Limits{Input: ptr(922000), Context: ptr(1050000), Reserve: 131072}, 524288},
	} {
		t.Run(tc.name, func(t *testing.T) {
			limit := UsableInputBytes(tc.limits)
			if limit != tc.want {
				t.Fatalf("%d != %d", limit, tc.want)
			}
			for _, n := range []int{tc.want - 1, tc.want, tc.want + 1} {
				if FitsInputBytes(n, tc.limits) != (n <= tc.want) {
					t.Fatalf("boundary %d, limit %d", n, limit)
				}
			}
		})
	}
	for _, p := range Profiles().Profiles {
		if RequestInputBytes(Role{Provider: p.Provider, Model: p.Model}) != 524288 {
			t.Fatal(p.ID)
		}
	}
}

func TestProfileEvidenceScope(t *testing.T) {
	for _, p := range Profiles().Profiles {
		ids := map[string]bool{}
		for _, e := range p.Evidence {
			id := e["id"].(string)
			if ids[id] {
				t.Fatal(id)
			}
			ids[id] = true
		}
		for _, q := range p.Qualifications {
			want := "go-live-2026-10-24"
			if p.Provider == "chatgpt" && q.Role == "review" {
				want = "native-go-sol-review-2026-10-24"
			}
			if len(q.EvidenceIDs) != 1 || q.EvidenceIDs[0] != want || !ids[want] {
				t.Fatal(p.ID, q)
			}
		}
	}
	// Public text and JSON are generated from the same row-level scope.
	b, err := json.Marshal(Profiles())
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), `"max_input_tokens":null`) || !strings.Contains(OfficialText(), "review/high [native-go-sol-review-2026-10-24]") {
		t.Fatal(string(b))
	}
}

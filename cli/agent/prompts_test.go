package agent

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"slices"
	"strings"
	"testing"
)

// TestPromptsAreByteEqualToTheElixirFunctions compares the length and SHA-256 of each prompt
// with what the Elixir functions returned (testdata/gen_static.exs): the builder's,
// reviewer's, shaper's, refine's and init's instructions, the three guidance passages and
// the testing rules.
func TestPromptsAreByteEqualToTheElixirFunctions(t *testing.T) {
	data, err := os.ReadFile("testdata/prompts_golden.json")
	if err != nil {
		t.Fatal(err)
	}
	var want map[string]struct {
		Bytes  int
		Sha256 string
	}
	if err := json.Unmarshal(data, &want); err != nil {
		t.Fatal(err)
	}
	if len(want) != len(Names()) {
		t.Fatalf("golden has %d prompts, package has %d", len(want), len(Names()))
	}
	for _, name := range Names() {
		t.Run(name, func(t *testing.T) {
			w, ok := want[name]
			if !ok {
				t.Fatalf("no golden entry for %s", name)
			}
			text := Prompt(name)
			sum := sha256.Sum256([]byte(text))
			if len(text) != w.Bytes || hex.EncodeToString(sum[:]) != w.Sha256 {
				t.Errorf("%s: %d bytes sha256 %x, want %d bytes sha256 %s", name, len(text), sum, w.Bytes, w.Sha256)
			}
			if strings.Contains(text, "{{") {
				t.Errorf("%s has an unreplaced placeholder", name)
			}
		})
	}
}

func TestTheTestingRulesUsersReadAreTheOnesEmbedded(t *testing.T) {
	docs, err := os.ReadFile("../../docs/testing-rules.md")
	if err != nil {
		t.Fatal(err)
	}
	if string(docs) != Prompt(TestingRules) {
		t.Error("docs/testing-rules.md and agent/prompts/testing-rules.md differ: copy the docs file over the embedded one")
	}
}

func TestShaperAndRefineShareTheGuidancePassages(t *testing.T) {
	feasibility, acknowledgment := Prompt(FeasibilityGuidance), Prompt(ReadinessAcknowledgmentGuidance)
	for _, name := range []string{Shaper, Refine} {
		text := Prompt(name)
		if strings.Count(text, feasibility) != 1 || strings.Count(text, acknowledgment) != 1 {
			t.Errorf("%s must hold each guidance passage exactly once", name)
		}
	}
	for _, name := range []string{Builder, Reviewer, Init} {
		if strings.Contains(Prompt(name), feasibility) {
			t.Errorf("%s holds the feasibility guidance", name)
		}
	}
	if !strings.Contains(string(mustJSON(t, Defs(SubmitTool)[0])), jsonText(t, acknowledgment)) {
		t.Error("the submit definition lost the acknowledgment guidance")
	}
}

func TestRender(t *testing.T) {
	vars := map[string]string{"a": "1", "long name": "two words"}
	for _, c := range []struct{ template, want string }{
		{"", ""},
		{"no placeholder", "no placeholder"},
		{"{{a}}", "1"},
		{"x {{a}} y {{a}}{{long name}}", "x 1 y 1two words"},
		{"{{unknown}} {{a}}", "{{unknown}} 1"},
		{"{a} {{a} {{ a }}", "{a} {{a} {{ a }}"},
		{"{{{a}}}", "{1}"},
	} {
		if got := Render(c.template, vars); got != c.want {
			t.Errorf("Render(%q) = %q, want %q", c.template, got, c.want)
		}
	}
	if got := Render("{{a}}", nil); got != "{{a}}" {
		t.Errorf("without variables: %q", got)
	}
	// A value is not scanned again.
	if got := Render("{{a}}", map[string]string{"a": "{{b}}", "b": "x"}); got != "{{b}}" {
		t.Errorf("value rescanned: %q", got)
	}
}

func TestUnknownPromptAndToolNamesPanic(t *testing.T) {
	for name, f := range map[string]func(){
		"prompt": func() { Prompt("nope") },
		"tool":   func() { Defs("nope") },
	} {
		func() {
			defer func() {
				if recover() == nil {
					t.Errorf("unknown %s did not panic", name)
				}
			}()
			f()
		}()
	}
}

func TestNamesListsEveryPrompt(t *testing.T) {
	entries, err := os.ReadDir("prompts")
	if err != nil {
		t.Fatal(err)
	}
	var files []string
	for _, e := range entries {
		files = append(files, strings.TrimSuffix(e.Name(), ".md"))
	}
	names := slices.Clone(Names())
	slices.Sort(files)
	slices.Sort(names)
	if !slices.Equal(files, names) {
		t.Errorf("prompt files %v, names %v", files, names)
	}
}

func mustJSON(t *testing.T, v any) []byte {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// jsonText is s as it appears inside a JSON string, without the quotes.
func jsonText(t *testing.T, s string) string {
	t.Helper()
	b := mustJSON(t, s)
	return string(b[1 : len(b)-1])
}

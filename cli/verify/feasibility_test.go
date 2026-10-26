package verify

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"kogen-loop/sys"
	"kogen/project"
)

type feasGolden struct {
	Declarations []struct {
		Name        string        `json:"name"`
		Feasibility []string      `json:"feasibility"`
		Acceptance  []string      `json:"acceptance"`
		OK          []Declaration `json:"ok"`
		Error       *struct {
			Detail string
			Lines  []string
			Class  string
			Reason string
			Exit   int
		} `json:"error"`
	} `json:"declarations"`
	Valid []struct {
		Name        string                     `json:"name"`
		Feasibility []string                   `json:"feasibility"`
		Acceptance  []string                   `json:"acceptance"`
		Files       map[string]json.RawMessage `json:"files"`
		Proof       json.RawMessage            `json:"proof"`
		Valid       bool                       `json:"valid"`
	} `json:"valid"`
	Observations []struct {
		Name  string `json:"name"`
		Ready struct {
			SHA256         string `json:"sha256"`
			Head           string `json:"head"`
			AcceptanceExit int    `json:"acceptance_exit"`
			Scenarios      []struct {
				Name   string  `json:"name"`
				Line   int     `json:"line"`
				Status string  `json:"status"`
				Detail *string `json:"detail"`
			} `json:"scenarios"`
		} `json:"ready"`
		Reference       *string `json:"reference"`
		Observations    string  `json:"observations"`
		Acknowledgement string  `json:"acknowledgment"`
	} `json:"observations"`
}

func evidenceIntent(acceptance, feasibility []string) *project.Intent {
	return &project.Intent{Slug: "controls", Acceptance: acceptance, Feasibility: feasibility}
}

func TestDeclarationsEqualTheElixirReadingOnEveryReference(t *testing.T) {
	var g feasGolden
	readGolden(t, "feasibility.json", &g)
	if len(g.Declarations) < 40 {
		t.Fatal("missing reference cases")
	}
	for _, c := range g.Declarations {
		t.Run(c.Name, func(t *testing.T) {
			got, err := Declarations(evidenceIntent(c.Acceptance, c.Feasibility))
			if c.Error != nil {
				e, ok := sys.AsError(err)
				if !ok {
					t.Fatalf("err = %v, want intent/not_ready", err)
				}
				if e.Class != c.Error.Class || e.Reason != c.Error.Reason || e.Detail != c.Error.Detail {
					t.Fatalf("error = %s", e.Render())
				}
				if !slices.Equal(e.Lines, c.Error.Lines) || e.Exit != c.Error.Exit {
					t.Fatalf("lines = %q exit %d, want %q exit %d", e.Lines, e.Exit, c.Error.Lines, c.Error.Exit)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if encode(got) != encode(c.OK) && !(len(got) == 0 && len(c.OK) == 0) {
				t.Fatalf("declarations = %s, want %s", encode(got), encode(c.OK))
			}
		})
	}
}

func TestValidEqualsTheElixirVerdictOnEveryReference(t *testing.T) {
	var g feasGolden
	readGolden(t, "feasibility.json", &g)
	for _, c := range g.Valid {
		t.Run(c.Name, func(t *testing.T) {
			root := t.TempDir()
			for path, raw := range c.Files {
				full := filepath.Join(root, path)
				os.MkdirAll(filepath.Dir(full), 0o755)
				var link struct{ Symlink string }
				if json.Unmarshal(raw, &link) == nil && link.Symlink != "" {
					if err := os.Symlink(link.Symlink, full); err != nil {
						t.Fatal(err)
					}
					continue
				}
				var text string
				json.Unmarshal(raw, &text)
				if err := os.WriteFile(full, []byte(text), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			var proof any
			d := json.NewDecoder(strings.NewReader(string(c.Proof)))
			d.UseNumber()
			if err := d.Decode(&proof); err != nil {
				t.Fatal(err)
			}
			if got := Valid(root, evidenceIntent(c.Acceptance, c.Feasibility), proof); got != c.Valid {
				t.Fatalf("Valid = %v, want %v", got, c.Valid)
			}
		})
	}
}

func TestObservationsAndAcknowledgmentEqualTheElixirTexts(t *testing.T) {
	var g feasGolden
	readGolden(t, "feasibility.json", &g)
	for _, c := range g.Observations {
		t.Run(c.Name, func(t *testing.T) {
			ready := &Ready{SHA256: c.Ready.SHA256, Head: c.Ready.Head, AcceptanceExit: c.Ready.AcceptanceExit}
			for _, s := range c.Ready.Scenarios {
				ready.Scenarios = append(ready.Scenarios, ScenarioResult{Name: s.Name, Line: s.Line, Status: s.Status, Detail: s.Detail})
			}
			ref := ""
			if c.Reference != nil {
				ref = *c.Reference
			}
			if got := Observations("obs", ready, ref); got != c.Observations {
				t.Fatalf("observations differ\n got: %q\nwant: %q", got, c.Observations)
			}
			if got := Acknowledgment("obs", ready, ref); got != c.Acknowledgement {
				t.Fatalf("acknowledgment differs\n got: %q\nwant: %q", got, c.Acknowledgement)
			}
		})
	}
}

// ---- ExUnit: feasibility_test.exs ----

func capabilityDeclaration() Declaration {
	return Declaration{ID: "route", Kind: "capability", Inputs: []string{"route.cjs"}, Observers: []string{},
		Checks: []DeclaredCheck{{Name: "support", Command: "node route.cjs", Exit: 23, Output: "explicit rejection\n"}}}
}

func evidenceLines(ds ...Declaration) []string {
	var lines []string
	for _, d := range ds {
		lines = append(lines, "- evidence: "+encode(d))
	}
	return lines
}

func TestOrdinaryVersion3RecordsNeedNoFeasibilityProof(t *testing.T) {
	in := evidenceIntent([]string{"observer.cjs"}, nil)
	if !Valid("unused", in, nil) || !Valid("unused", in, []Obligation{}) || !Valid("unused", in, []any{}) {
		t.Fatal("a record without declarations needs no proof")
	}
}

func TestDeclarationsRequireUniqueIDsAndOrderedActualObserverControls(t *testing.T) {
	d := capabilityDeclaration()
	got, err := Declarations(evidenceIntent([]string{"observer.cjs"}, evidenceLines(d)))
	if err != nil || len(got) != 1 || encode(got[0]) != encode(d) {
		t.Fatalf("declarations = %v, %v", got, err)
	}
	if _, err := Declarations(evidenceIntent([]string{"observer.cjs"}, evidenceLines(d, d))); err == nil {
		t.Fatal("duplicate ids must be refused")
	}
	obs := d
	obs.Kind, obs.Observers = "observer", []string{"observer.cjs"}
	if _, err := Declarations(evidenceIntent([]string{"observer.cjs"}, evidenceLines(obs))); err == nil {
		t.Fatal("an observer needs its good and bad controls")
	}
}

func TestRejectionEvidenceBindsCommandBytesAndCompleteActualOutcome(t *testing.T) {
	root := t.TempDir()
	os.WriteFile(filepath.Join(root, "route.cjs"), []byte("original"), 0o644)
	d := capabilityDeclaration()
	in := evidenceIntent([]string{"observer.cjs"}, evidenceLines(d))
	check := map[string]any{"name": "support", "command": "node route.cjs", "exit": 23, "output": "explicit rejection\n", "timed_out": false}
	proof := func(c map[string]any) []any {
		return []any{map[string]any{"id": "route", "kind": "capability", "observers": map[string]any{},
			"inputs": map[string]any{"route.cjs": sha("original")}, "checks": []any{c}}}
	}
	if !Valid(root, in, proof(check)) {
		t.Fatal("exact evidence must be valid")
	}
	if Valid(root, in, nil) || Valid(root, in, []any{}) {
		t.Fatal("declared evidence needs proof")
	}
	for key, value := range map[string]any{"exit": 0, "timed_out": true, "output": "supported\n", "command": "old driver"} {
		changed := map[string]any{}
		for k, v := range check {
			changed[k] = v
		}
		changed[key] = value
		if Valid(root, in, proof(changed)) {
			t.Fatalf("evidence with another %s must not qualify", key)
		}
	}
	os.WriteFile(filepath.Join(root, "route.cjs"), []byte("changed"), 0o644)
	if Valid(root, in, proof(check)) {
		t.Fatal("evidence must not qualify other bytes")
	}
}

// Ports test/kogen/feasibility_test.exs "observer polarity cannot be waived by matching
// successful or rejected controls".
func TestObserverPolarityCannotBeWaivedByMatchingSuccessfulOrRejectedControls(t *testing.T) {
	declare := func(good, bad int) string {
		b, _ := json.Marshal(map[string]any{
			"id": "route", "kind": "observer", "inputs": []string{"route.cjs"}, "observers": []string{"observer.cjs"},
			"checks": []any{
				map[string]any{"name": "good", "command": "probe", "exit": good, "output": ""},
				map[string]any{"name": "bad", "command": "probe", "exit": bad, "output": ""},
			},
		})
		return "- evidence: " + string(b)
	}
	intent := func(line string) *project.Intent {
		return &project.Intent{Slug: "controls", Acceptance: []string{"observer.cjs"}, Feasibility: []string{line}}
	}
	got, err := Declarations(intent(declare(0, 1)))
	if err != nil || len(got) != 1 || got[0].Checks[0].Exit != 0 || got[0].Checks[1].Exit != 1 {
		t.Fatalf("the good control passes and the bad one is rejected: %v, %v", got, err)
	}
	if _, err := Declarations(intent(declare(0, 2))); err != nil {
		t.Fatalf("any nonzero rejection is a bad control: %v", err)
	}
	for _, c := range []struct{ good, bad int }{{1, 1}, {0, 0}, {1, 0}, {2, 0}} {
		t.Run(fmt.Sprintf("good %d bad %d", c.good, c.bad), func(t *testing.T) {
			_, err := Declarations(intent(declare(c.good, c.bad)))
			e, ok := sys.AsError(err)
			if !ok || e.Class != "intent" || e.Reason != "not_ready" || e.Detail != "invalid feasibility evidence" ||
				!strings.Contains(strings.Join(e.Lines, ""), "observer good must expect exit 0 and bad a NONZERO integer exit") {
				t.Fatalf("error %v", err)
			}
			if Valid(t.TempDir(), intent(declare(c.good, c.bad)), []any{}) {
				t.Fatal("an invalid declaration qualified")
			}
		})
	}
	// A capability may legitimately expect a nonzero support exit.
	capability, _ := json.Marshal(map[string]any{
		"id": "route", "kind": "capability", "inputs": []string{"route.cjs"}, "observers": []string{},
		"checks": []any{map[string]any{"name": "support", "command": "node route.cjs", "exit": 23, "output": "explicit rejection\n"}},
	})
	if got, err := Declarations(intent("- evidence: " + string(capability))); err != nil || len(got) != 1 || got[0].Checks[0].Exit != 23 {
		t.Fatalf("capability %v, %v", got, err)
	}
}

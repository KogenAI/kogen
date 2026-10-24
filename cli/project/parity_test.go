package project

import (
	"encoding/json"
	"os"
	"slices"
	"testing"
)

// parity.json pins what the Elixir Kogen computed for three real Intent packages of this
// repository (Kogen.Intent.baseline/3 and hash/2, via `mix run`): the baseline file list in card
// order and the approval hash, over the exact bytes of those files, which parity.json carries.
// The approval hash a user types must be identical between the two implementations.
func TestIntentHashMatchesElixir(t *testing.T) {
	b, err := os.ReadFile("testdata/parity.json")
	if err != nil {
		t.Fatal(err)
	}
	var parity struct {
		Cases []struct {
			Slug, Hash string
			Baseline   []string
		}
		Files map[string]string
	}
	if err := json.Unmarshal(b, &parity); err != nil {
		t.Fatal(err)
	}
	if len(parity.Cases) < 3 {
		t.Fatalf("only %d pinned packages", len(parity.Cases))
	}
	root := gitRepo(t)
	for p, content := range parity.Files {
		writeFile(t, root, p, content)
	}
	cfg, err := LoadConfig(root)
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(cfg.Protect, []string{".formatter.exs", "mix.exs"}) || cfg.Models["shape"] != (Role{Provider: "supergrok", Model: "grok-4.7", Effort: "high"}) {
		t.Fatalf("pinned configuration read as %+v", cfg)
	}
	for _, c := range parity.Cases {
		t.Run(c.Slug, func(t *testing.T) {
			baseline, err := Baseline(root, c.Slug, cfg)
			if err != nil {
				t.Fatal(err)
			}
			if !slices.Equal(baseline, c.Baseline) {
				t.Errorf("baseline\n got %q\nwant %q", baseline, c.Baseline)
			}
			if got := Hash(root, baseline); got != c.Hash {
				t.Errorf("hash %s, want %s", got, c.Hash)
			}
			// Reading and checking the package must work on the same files.
			if in, err := LoadIntent(root, c.Slug); err != nil || in.Title == "" || len(in.Acceptance) < 2 {
				t.Errorf("intent %+v %v", in, err)
			}
			if _, scenarios, err := CheckIntent(root, c.Slug, nil); err != nil || len(scenarios) == 0 {
				t.Errorf("check: %v (%d scenarios)", err, len(scenarios))
			}
		})
	}
}

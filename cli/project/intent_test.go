package project

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"math/rand"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"kogen/sys"
)

const demoSlug = "demo-intent"

// demoIntent writes a valid Intent under root with these parts replaced where given.
type demoParts struct{ title, slug, model, acc, dec, feas, tests *string }

func demoMD(p demoParts) string {
	pick := func(v *string, def string) string {
		if v != nil {
			return *v
		}
		return def
	}
	return strings.Join([]string{
		pick(p.title, "# Demo title"),
		pick(p.slug, "Slug: "+demoSlug),
		pick(p.model, "Model: not applicable — display only"),
		pick(p.acc, "Acceptance:\n- "+FeaturePath(demoSlug)),
		"",
		"prose",
		"",
		pick(p.dec, "## Decisions\n\n- Do it (source: request)\n"),
		pick(p.feas, "## Feasibility\n\n- none\n"),
		pick(p.tests, "## Tests\n\n- rule: add a test (unit)\n"),
	}, "\n")
}

func sp(s string) *string { return &s }

const goodFeature = "Feature: F\n  Scenario: s\n    Then it works\n"

func intentRoot(t *testing.T) string {
	t.Helper()
	root := gitRepo(t)
	writeFile(t, root, ".gitignore", "ignored.js\nbuild/\n")
	return root
}

func problemsOf(t *testing.T, err error, reason string) []string {
	t.Helper()
	se, ok := sys.AsError(err)
	if !ok || se.Class != "intent" || se.Reason != reason || se.Exit != 1 {
		t.Fatalf("got %v, want intent/%s", err, reason)
	}
	want := map[string]string{"parse": "the Intent cannot be read", "lint": "the Intent needs changes"}[reason]
	if se.Detail != want {
		t.Errorf("detail %q", se.Detail)
	}
	return se.Lines
}

func TestIntentAcceptanceListsReadAndLintWithLeadingBlankLines(t *testing.T) {
	// ExUnit: SHP-5: formatted Acceptance lists read and lint with leading blank lines
	root := gitRepo(t)
	feature := FeaturePath("reading-time")
	steps := "features/steps/reading_time.js"
	writeFile(t, root, feature, "Feature: Reading time\n  Scenario: Estimate\n    Then it is shown\n")
	writeFile(t, root, steps, "// acceptance steps\n")
	for _, spacing := range []string{"", "\n", "\n \t\n"} {
		writeFile(t, root, IntentMDPath("reading-time"), "# Reading time\nSlug: reading-time\nModel: not applicable — display calculation\nAcceptance:\n"+spacing+"- "+feature+"\n- "+steps+`

## Decisions

- Show the estimate (source: request)

## Feasibility

- none

## Tests

- estimate: detail route displays reading time (regression)
`)
		in, err := LoadIntent(root, "reading-time")
		if err != nil || !slices.Equal(in.Acceptance, []string{feature, steps}) {
			t.Fatalf("spacing %q: read %v %v", spacing, in, err)
		}
		checked, scenarios, err := CheckIntent(root, "reading-time", nil)
		if err != nil || len(scenarios) != 1 || !slices.Equal(checked.Acceptance, []string{feature, steps}) {
			t.Fatalf("spacing %q: check %v %v", spacing, err, scenarios)
		}
	}
}

func TestIntentAcceptanceOnlySkipsBlanksBeforeFirstBullet(t *testing.T) {
	// ExUnit: SHP-5: Acceptance only skips blanks before the first bullet
	path := IntentMDPath("reading-time")
	feature := FeaturePath("reading-time")
	read := func(text string) []string {
		in, err := ReadIntent(t.TempDir(), "reading-time", map[string][]byte{path: []byte(text)})
		if err != nil {
			t.Fatal(err)
		}
		return in.Acceptance
	}
	for _, boundary := range []string{"", "ordinary text", "## Decisions"} {
		if got := read("Acceptance:\n\n- " + feature + "\n" + boundary + "\n- unrelated\n"); !slices.Equal(got, []string{feature}) {
			t.Errorf("boundary %q: %v", boundary, got)
		}
	}
	if got := read("Acceptance:\n\n## Decisions\n- unrelated\n"); len(got) != 0 {
		t.Errorf("no bullets: %v", got)
	}
}

func randomContents(r *rand.Rand, min, max int) []string {
	const alnum = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	out := make([]string, min+r.Intn(max-min+1))
	for i := range out {
		b := make([]byte, r.Intn(25))
		for j := range b {
			b[j] = alnum[r.Intn(len(alnum))]
		}
		out[i] = string(b)
	}
	return out
}

func TestHashChangesWithAnyBaselineChange(t *testing.T) {
	// ExUnit: AUT-2 / VER-1: changing, adding, removing, or renaming any baseline file changes its hash
	r := rand.New(rand.NewSource(1))
	for round := 0; round < 40; round++ {
		root := t.TempDir()
		contents := randomContents(r, 1, 6)
		var paths []string
		for i, c := range contents {
			p := "baseline/file-" + string(rune('0'+i)) + ".txt"
			paths = append(paths, p)
			writeFile(t, root, p, c)
		}
		original := Hash(root, paths)
		first := paths[0]

		writeFile(t, root, first, contents[0]+"changed")
		if Hash(root, paths) == original {
			t.Fatalf("round %d: a changed file kept the hash", round)
		}
		writeFile(t, root, first, contents[0])

		writeFile(t, root, "baseline/added.txt", "new baseline file")
		if Hash(root, append(slices.Clone(paths), "baseline/added.txt")) == original {
			t.Fatalf("round %d: an added file kept the hash", round)
		}
		os.Remove(filepath.Join(root, "baseline/added.txt"))

		os.Remove(filepath.Join(root, first))
		if Hash(root, paths[1:]) == original {
			t.Fatalf("round %d: a removed file kept the hash", round)
		}
		if Hash(root, paths) == original {
			t.Fatalf("round %d: a missing file kept the hash", round)
		}
		writeFile(t, root, first, contents[0])

		os.Rename(filepath.Join(root, first), filepath.Join(root, "baseline/renamed.txt"))
		if Hash(root, append(slices.Clone(paths[1:]), "baseline/renamed.txt")) == original {
			t.Fatalf("round %d: a renamed file kept the hash", round)
		}
	}
}

func TestHashIgnoresListingOrder(t *testing.T) {
	// ExUnit: AUT-2: the approval hash does not depend on baseline listing order
	r := rand.New(rand.NewSource(2))
	for round := 0; round < 40; round++ {
		root := t.TempDir()
		contents := randomContents(r, 2, 6)
		var paths []string
		for i, c := range contents {
			p := "baseline/file-" + string(rune('0'+i)) + ".txt"
			paths = append(paths, p)
			writeFile(t, root, p, c)
		}
		want := Hash(root, paths)
		rev := slices.Clone(paths)
		slices.Reverse(rev)
		shuffled := slices.Clone(paths)
		r.Shuffle(len(shuffled), func(i, j int) { shuffled[i], shuffled[j] = shuffled[j], shuffled[i] })
		if Hash(root, rev) != want || Hash(root, shuffled) != want {
			t.Fatalf("round %d: the hash depends on order", round)
		}
		if !slices.Equal(paths, slices.Sorted(slices.Values(paths))) {
			t.Fatal("the input list was reordered")
		}
	}
}

func TestHashFormat(t *testing.T) {
	root := t.TempDir()
	writeFile(t, root, "a.txt", "hello")
	// sha256("a.txt\0" + sha256("hello") + "\n" + "gone.txt\0missing\n")
	got := Hash(root, []string{"gone.txt", "a.txt"})
	if len(got) != 64 || strings.ToLower(got) != got {
		t.Errorf("hash %q", got)
	}
	if got != Hash(root, []string{"a.txt", "gone.txt"}) {
		t.Error("order matters")
	}
	if got == Hash(root, []string{"a.txt"}) {
		t.Error("a missing file does not count")
	}
	if Hash(root, nil) != "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" {
		t.Errorf("empty hash %q", Hash(root, nil))
	}
	// A folder cannot be read as a file, so it counts as missing.
	writeFile(t, root, "dir/inner.txt", "x")
	sum := sha256.Sum256([]byte("dir\x00missing\n"))
	if Hash(root, []string{"dir"}) != hex.EncodeToString(sum[:]) {
		t.Error("a folder is not hashed as missing")
	}
	fileSum := sha256.Sum256([]byte("hello"))
	line := "a.txt\x00" + hex.EncodeToString(fileSum[:]) + "\n"
	want := sha256.Sum256([]byte(line))
	if Hash(root, []string{"a.txt"}) != hex.EncodeToString(want[:]) {
		t.Error("the hash is not over path, NUL, file digest and newline")
	}
}

func TestProtectedPathsFoldersAndGlobs(t *testing.T) {
	// ExUnit: VER-1: protect paths, folders, and globs select the matching Git files and no neighbors
	root := gitRepo(t)
	files := map[string]string{
		".credo.exs":                    "rules",
		".credo.exs.bak":                "backup",
		"config/linter.exs":             "config",
		"config/nested/rules.exs":       "nested config",
		"configurator/linter.exs":       "neighbor",
		"checks/unit.yml":               "unit",
		"checks/nested/integration.yml": "integration",
		"checks/unit.yaml":              "other extension",
		"style/base.cfg":                "direct",
		"style/nested/extra.cfg":        "nested",
		"style-backup/base.cfg":         "neighbor",
		"notes.txt":                     "unprotected",
		".gitignore":                    "checks/ignored.yml\n",
	}
	for p, c := range files {
		writeFile(t, root, p, c)
	}
	git(t, root, "add", ".")
	git(t, root, "commit", "-m", "fixture", "--no-gpg-sign")
	writeFile(t, root, "checks/ignored.yml", "ignored")
	writeFile(t, root, "untracked/new.cfg", "untracked but not ignored")

	got, err := Protected(root, &Config{Protect: []string{".credo.exs", "config/", "checks/**/*.yml", "style/*.cfg"}})
	if err != nil {
		t.Fatal(err)
	}
	want := []string{".credo.exs", "checks/nested/integration.yml", "checks/unit.yml", "config/linter.exs", "config/nested/rules.exs", "style/base.cfg"}
	if !slices.Equal(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
	more, err := Protected(root, &Config{Protect: []string{"untracked/*.cfg", "**/rules.exs", "co?fig/linter.exs", "config/", "config//"}})
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"config/linter.exs", "config/nested/rules.exs", "untracked/new.cfg"}; !slices.Equal(more, want) {
		t.Errorf("got %v, want %v", more, want)
	}
	if none, err := Protected(root, &Config{}); err != nil || len(none) != 0 {
		t.Errorf("no patterns: %v %v", none, err)
	}
	if _, err := Protected(t.TempDir(), &Config{Protect: []string{"x"}}); err == nil {
		t.Error("a folder that is not a repository did not fail")
	}
}

func git(t *testing.T, root string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = root
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v: %s", args, err, out)
	}
	return string(out)
}

func TestGlobRegexp(t *testing.T) {
	cases := []struct {
		pat, path string
		want      bool
	}{
		{"a.b", "a.b", true},
		{"a.b", "axb", false},
		{"*.go", "x.go", true},
		{"*.go", "d/x.go", false},
		{"**/x.go", "x.go", true},
		{"**/x.go", "a/b/x.go", true},
		{"a/**", "a/b/c", true},
		{"a/**", "a", false},
		{"a?c", "abc", true},
		{"a?c", "a/c", false},
		{"[x]", "[x]", true},
		{"[x]", "x", false},
		{"a+b", "a+b", true},
		{"**x", "d/e/x", true},
	}
	for _, c := range cases {
		if got := globRegexp(c.pat).MatchString(c.path); got != c.want {
			t.Errorf("glob %q on %q = %v", c.pat, c.path, got)
		}
	}
}

func TestCheckIntentRules(t *testing.T) {
	model := ModelPath(demoSlug)
	feature := FeaturePath(demoSlug)
	goodModel := "module m {\n  val Inv = true\n  def Other = 1\n}\n"
	cases := []struct {
		name    string
		parts   demoParts
		files   map[string]string // beside intent.md; the feature defaults to a good one
		reason  string            // "" = valid
		problem []string
	}{
		{name: "valid"},
		{name: "no title", parts: demoParts{title: sp("no title line")}, reason: "lint", problem: []string{"title: intent.md must start with a # title"}},
		{name: "empty title", parts: demoParts{title: sp("# ")}, reason: "lint", problem: []string{"title: intent.md must start with a # title"}},
		{name: "title of 51", parts: demoParts{title: sp("# " + strings.Repeat("a", 51))}, reason: "lint", problem: []string{"title: the title must be at most 50 characters"}},
		{name: "title of 50", parts: demoParts{title: sp("# " + strings.Repeat("a", 50))}},
		{name: "title counts characters not bytes", parts: demoParts{title: sp("# " + strings.Repeat("日", 50))}},
		{name: "title counts a combining mark once", parts: demoParts{title: sp("# " + strings.Repeat("é", 50))}},
		{name: "title counts an emoji sequence once", parts: demoParts{title: sp("# " + strings.Repeat("👩‍👩‍👧", 40) + strings.Repeat("🇧🇦", 10))}},
		{name: "title period", parts: demoParts{title: sp("# Ends with period.")}, reason: "lint", problem: []string{"title: the title must not end with a period"}},
		{name: "wrong slug", parts: demoParts{slug: sp("Slug: other")}, reason: "lint", problem: []string{"slug: the Slug: line must be demo-intent"}},
		{name: "missing slug", parts: demoParts{slug: sp("")}, reason: "lint", problem: []string{"slug: the Slug: line must be demo-intent"}},
		{name: "slug is trimmed", parts: demoParts{slug: sp("Slug:   demo-intent  ")}},
		{name: "missing model", parts: demoParts{model: sp("")}, reason: "lint", problem: []string{"model: the Model: line must be `not applicable — <reason>` or `.kogen/intents/demo-intent/model.qnt invariants=<Name> seed=<n> samples=<n> steps=<n>`"}},
		{name: "model without reason", parts: demoParts{model: sp("Model: not applicable — ")}, reason: "lint", problem: []string{"model: the Model: line must be `not applicable — <reason>` or `.kogen/intents/demo-intent/model.qnt invariants=<Name> seed=<n> samples=<n> steps=<n>`"}},
		{name: "model with hyphen", parts: demoParts{model: sp("Model: not applicable - because")}},
		{name: "model named", parts: demoParts{model: sp("Model: " + model + " invariants=Inv,Other seed=1 samples=2 steps=3")}, files: map[string]string{model: goodModel}},
		{name: "model file missing", parts: demoParts{model: sp("Model: " + model + " invariants=Inv seed=1 samples=2 steps=3")}, reason: "lint", problem: []string{"model: " + model + " does not exist"}},
		{name: "model elsewhere", parts: demoParts{model: sp("Model: other.qnt invariants=Inv seed=1 samples=2 steps=3")}, reason: "lint", problem: []string{"model: the model must be " + model}},
		{name: "invariants missing", parts: demoParts{model: sp("Model: " + model + " invariants=Inv,Nope,Gone seed=1 samples=2 steps=3")}, files: map[string]string{model: goodModel}, reason: "lint", problem: []string{"model: invariant Nope does not exist in model.qnt", "model: invariant Gone does not exist in model.qnt"}},
		{name: "invariant is a whole word", parts: demoParts{model: sp("Model: " + model + " invariants=In seed=1 samples=2 steps=3")}, files: map[string]string{model: goodModel}, reason: "lint", problem: []string{"model: invariant In does not exist in model.qnt"}},
		{name: "acceptance must start with the feature", parts: demoParts{acc: sp("Acceptance:\n- other.js\n- " + feature)}, reason: "lint", problem: []string{"acceptance: the Acceptance: list must start with " + feature}},
		{name: "no acceptance list", parts: demoParts{acc: sp("")}, reason: "lint", problem: []string{"acceptance: the Acceptance: list must start with " + feature}},
		{name: "acceptance file missing", parts: demoParts{acc: sp("Acceptance:\n- " + feature + "\n- features/steps/x.js")}, reason: "lint", problem: []string{"acceptance: features/steps/x.js does not exist"}},
		{name: "acceptance file present", parts: demoParts{acc: sp("Acceptance:\n- " + feature + "\n- features/steps/x.js")}, files: map[string]string{"features/steps/x.js": "//"}},
		{name: "acceptance file ignored", parts: demoParts{acc: sp("Acceptance:\n- " + feature + "\n- ignored.js")}, files: map[string]string{"ignored.js": "//"}, reason: "lint", problem: []string{"acceptance: ignored.js is ignored by Git"}},
		{name: "acceptance folder ignored", parts: demoParts{acc: sp("Acceptance:\n- " + feature + "\n- build/out.js")}, files: map[string]string{"build/out.js": "//"}, reason: "lint", problem: []string{"acceptance: build/out.js is ignored by Git"}},
		{name: "decision without source", parts: demoParts{dec: sp("## Decisions\n\n- Do it\n- Other (source: answer 2)\n")}, reason: "lint", problem: []string{"decisions: a decision has no source"}},
		{name: "decision from an answer", parts: demoParts{dec: sp("## Decisions\n- Do it (source: answer 12)  \n")}},
		{name: "decision from a bad answer", parts: demoParts{dec: sp("## Decisions\n- Do it (source: answer x)\n")}, reason: "lint", problem: []string{"decisions: a decision has no source"}},
		{name: "no decisions is fine", parts: demoParts{dec: sp("")}},
		{name: "no feasibility", parts: demoParts{feas: sp("")}, reason: "lint", problem: []string{"feasibility: intent.md needs a ## Feasibility section listing each probe, or - none"}},
		{name: "feasibility without items", parts: demoParts{feas: sp("## Feasibility\n\nprose\n\n")}, reason: "lint", problem: []string{"feasibility: intent.md needs a ## Feasibility section listing each probe, or - none"}},
		{name: "no tests", parts: demoParts{tests: sp("")}, reason: "lint", problem: []string{"tests: the ## Tests section is missing or empty"}},
		{name: "tests without items", parts: demoParts{tests: sp("## Tests\n\nprose\n")}, reason: "lint", problem: []string{"tests: the ## Tests section is missing or empty"}},
		{name: "tests with bad lines", parts: demoParts{tests: sp("## Tests\n- no layer here\n- none: \n- none: reason\n- rule: thing (bogus)\n- rule: thing (existing)\n- a: b (integration)\n")}, reason: "lint", problem: []string{
			"tests: - no layer here must be `- <rule>: <test to add or update> (<layer>)` or `- none: <reason>`",
			"tests: - none:  must be `- <rule>: <test to add or update> (<layer>)` or `- none: <reason>`",
			"tests: - rule: thing (bogus) must be `- <rule>: <test to add or update> (<layer>)` or `- none: <reason>`",
		}},
		{name: "tests none", parts: demoParts{tests: sp("## Tests\n- none: copy change\n")}},
		{name: "no scenario", files: map[string]string{FeaturePath(demoSlug): "Feature: F\n"}, reason: "lint", problem: []string{"acceptance: acceptance.feature has no scenario"}},
		{name: "scenario without Then", files: map[string]string{FeaturePath(demoSlug): "Feature: F\n  Scenario: s\n    Given a\n    And b\n"}, reason: "lint", problem: []string{"acceptance: scenario s has no Then step"}},
		{name: "star is not Then", files: map[string]string{FeaturePath(demoSlug): "Feature: F\n  Scenario: s\n    * a\n"}, reason: "lint", problem: []string{"acceptance: scenario s has no Then step"}},
		{name: "forbidden tags", files: map[string]string{FeaturePath(demoSlug): "@wip\nFeature: F\n  @skip @manual\n  Scenario: s\n    Then a\n  @ignore\n  Scenario: t\n    Given b\n"}, reason: "lint", problem: []string{
			"acceptance: scenario s is tagged @wip", "acceptance: scenario s is tagged @skip", "acceptance: scenario s is tagged @manual",
			"acceptance: scenario t is tagged @wip", "acceptance: scenario t is tagged @ignore", "acceptance: scenario t has no Then step",
		}},
		{name: "forbidden tag on an outline", files: map[string]string{FeaturePath(demoSlug): "Feature: F\n  @pending\n  Scenario Outline: o <x>\n    Then a\n    Examples:\n      | x |\n      | 1 |\n"}, reason: "lint", problem: []string{"acceptance: scenario o 1 is tagged @pending"}},
		{name: "acceptance not parseable", files: map[string]string{FeaturePath(demoSlug): "Feature: F\n  Scenario: s\n    Then a\n  stray words\n"}, reason: "parse", problem: []string{"acceptance.feature line 4: unexpected text: stray words"}},
		{name: "feature missing", files: map[string]string{FeaturePath(demoSlug): ""}, reason: "parse", problem: []string{"acceptance.feature does not exist"}},
		{name: "many problems in order", parts: demoParts{title: sp("no"), slug: sp(""), model: sp("Model: x"), tests: sp(""), acc: sp("Acceptance:\n- x"), dec: sp("## Decisions\n- d\n"), feas: sp("")}, reason: "lint", problem: []string{
			"title: intent.md must start with a # title",
			"slug: the Slug: line must be demo-intent",
			"model: the Model: line must be `not applicable — <reason>` or `.kogen/intents/demo-intent/model.qnt invariants=<Name> seed=<n> samples=<n> steps=<n>`",
			"tests: the ## Tests section is missing or empty",
			"acceptance: the Acceptance: list must start with " + feature,
			"decisions: a decision has no source",
			"feasibility: intent.md needs a ## Feasibility section listing each probe, or - none",
		}},
	}
	root := intentRoot(t)
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			overlay := map[string][]byte{IntentMDPath(demoSlug): []byte(demoMD(c.parts)), FeaturePath(demoSlug): []byte(goodFeature)}
			for p, content := range c.files {
				if content == "" {
					delete(overlay, p)
				} else {
					overlay[p] = []byte(content)
				}
			}
			intent, scenarios, err := CheckIntent(root, demoSlug, overlay)
			if c.reason == "" {
				if err != nil || intent == nil || len(scenarios) != 1 {
					t.Fatalf("got %v", err)
				}
				return
			}
			if got := problemsOf(t, err, c.reason); !slices.Equal(got, c.problem) {
				t.Errorf("problems:\n got %q\nwant %q", got, c.problem)
			}
		})
	}
}

func TestCheckIntentMissingIntent(t *testing.T) {
	root := intentRoot(t)
	_, _, err := CheckIntent(root, demoSlug, nil)
	if got := problemsOf(t, err, "parse"); !slices.Equal(got, []string{"intent.md does not exist"}) {
		t.Errorf("problems %q", got)
	}
	_, err = LoadIntent(root, demoSlug)
	if got := problemsOf(t, err, "parse"); !slices.Equal(got, []string{"intent.md does not exist"}) {
		t.Errorf("problems %q", got)
	}
}

func TestCheckIntentReadsDiskAndOverlay(t *testing.T) {
	root := intentRoot(t)
	writeFile(t, root, IntentMDPath(demoSlug), demoMD(demoParts{}))
	writeFile(t, root, FeaturePath(demoSlug), goodFeature)
	if _, _, err := CheckIntent(root, demoSlug, nil); err != nil {
		t.Fatal(err)
	}
	// An overlay file wins over the disk and may be missing from it.
	overlay := map[string][]byte{FeaturePath(demoSlug): []byte("Feature: F\n")}
	_, _, err := CheckIntent(root, demoSlug, overlay)
	if got := problemsOf(t, err, "lint"); !slices.Equal(got, []string{"acceptance: acceptance.feature has no scenario"}) {
		t.Errorf("problems %q", got)
	}
	// The ignore check sees files on the disk even when they are untracked and ignored.
	writeFile(t, root, "ignored.js", "//")
	writeFile(t, root, IntentMDPath(demoSlug), demoMD(demoParts{acc: sp("Acceptance:\n- " + FeaturePath(demoSlug) + "\n- ignored.js")}))
	_, _, err = CheckIntent(root, demoSlug, nil)
	if got := problemsOf(t, err, "lint"); !slices.Equal(got, []string{"acceptance: ignored.js is ignored by Git"}) {
		t.Errorf("problems %q", got)
	}
	// A directory is not a regular file.
	writeFile(t, root, "dir/x.js", "//")
	writeFile(t, root, IntentMDPath(demoSlug), demoMD(demoParts{acc: sp("Acceptance:\n- " + FeaturePath(demoSlug) + "\n- dir")}))
	_, _, err = CheckIntent(root, demoSlug, nil)
	if got := problemsOf(t, err, "lint"); !slices.Equal(got, []string{"acceptance: dir does not exist"}) {
		t.Errorf("problems %q", got)
	}
}

func TestCheckIntentOutsideGitSkipsIgnoreCheck(t *testing.T) {
	gitSandbox(t)
	root := t.TempDir()
	writeFile(t, root, IntentMDPath(demoSlug), demoMD(demoParts{}))
	writeFile(t, root, FeaturePath(demoSlug), goodFeature)
	if _, _, err := CheckIntent(root, demoSlug, nil); err != nil {
		t.Fatal(err)
	}
}

func TestParseModelSpec(t *testing.T) {
	cases := []struct {
		line string
		want *ModelSpec
	}{
		{"not applicable — a pure function", &ModelSpec{None: true}},
		{"not applicable - reason", &ModelSpec{None: true}},
		{"not applicable—reason", &ModelSpec{None: true}},
		{"not applicable  — reason", &ModelSpec{None: true}},
		{"not applicable —", nil},
		{"not applicable — ", nil},
		{"not applicable", nil},
		{"not applicable because", nil},
		{"Not applicable — x", nil},
		{"a/b.qnt invariants=A seed=1 samples=2 steps=3", &ModelSpec{Path: "a/b.qnt", Invariants: []string{"A"}, Seed: "1", Samples: "2", Steps: "3"}},
		{"m.qnt invariants=A,b_2,_c seed=10 samples=200 steps=30", &ModelSpec{Path: "m.qnt", Invariants: []string{"A", "b_2", "_c"}, Seed: "10", Samples: "200", Steps: "30"}},
		{"m.qnt invariants=A, B seed=1 samples=2 steps=3", nil},
		{"m.qnt invariants=1A seed=1 samples=2 steps=3", nil},
		{"m.qnt invariants=A seed=x samples=2 steps=3", nil},
		{"m.qnt invariants=A seed=1 samples=2", nil},
		{"m.qnt invariants=A seed=1 samples=2 steps=3 extra", nil},
		{"m.txt invariants=A seed=1 samples=2 steps=3", nil},
		{"", nil},
	}
	for _, c := range cases {
		got := ParseModelSpec(c.line)
		if (got == nil) != (c.want == nil) || (got != nil && (got.None != c.want.None || got.Path != c.want.Path || !slices.Equal(got.Invariants, c.want.Invariants) || got.Seed != c.want.Seed || got.Samples != c.want.Samples || got.Steps != c.want.Steps)) {
			t.Errorf("%q: got %+v, want %+v", c.line, got, c.want)
		}
	}
}

func TestReadIntentFields(t *testing.T) {
	text := "# Title here \nSlug: demo-intent\nModel: not applicable — x\nAcceptance:\n- " + FeaturePath(demoSlug) + "\n- features/steps/a.js\n\n## Decisions\n- d1 (source: request)\nprose\n- d2\n\n## Tests\n- t1\n# Other\n- not a test\n\n## Feasibility\n- none\n"
	in, err := ReadIntent(t.TempDir(), demoSlug, map[string][]byte{IntentMDPath(demoSlug): []byte(text)})
	if err != nil {
		t.Fatal(err)
	}
	if in.Title != "Title here" || in.SlugLine != " demo-intent" || in.ModelLine != "not applicable — x" || in.Model == nil || !in.Model.None || in.Slug != demoSlug || in.Text != text {
		t.Errorf("fields %+v", in)
	}
	if !slices.Equal(in.Decisions, []string{"- d1 (source: request)", "- d2"}) || !slices.Equal(in.Tests, []string{"- t1"}) || !slices.Equal(in.Feasibility, []string{"- none"}) {
		t.Errorf("sections %q %q %q", in.Decisions, in.Tests, in.Feasibility)
	}
	if !slices.Equal(in.StepFiles(), []string{"features/steps/a.js"}) {
		t.Errorf("step files %v", in.StepFiles())
	}
	if !slices.Equal(in.Acceptance, []string{FeaturePath(demoSlug), "features/steps/a.js"}) {
		t.Errorf("acceptance mutated by StepFiles: %v", in.Acceptance)
	}
}

func TestIntentPathsAndExistence(t *testing.T) {
	if IntentDir("a-b") != ".kogen/intents/a-b" || FeaturePath("a-b") != ".kogen/intents/a-b/acceptance.feature" ||
		IntentMDPath("a-b") != ".kogen/intents/a-b/intent.md" || ModelPath("a-b") != ".kogen/intents/a-b/model.qnt" {
		t.Error("paths")
	}
	root := t.TempDir()
	if IntentExists(root, "a-b") {
		t.Error("exists")
	}
	err := RequireIntentDir(root, "a-b")
	if se, ok := sys.AsError(err); !ok || se.Render() != "intent/not_found: Intent does not exist\n" || se.Exit != 2 {
		t.Errorf("got %v", err)
	}
	writeFile(t, root, IntentMDPath("a-b"), "# x\n")
	if !IntentExists(root, "a-b") || RequireIntentDir(root, "a-b") != nil {
		t.Error("should exist")
	}
}

func TestBaselineOrderAndDuplicates(t *testing.T) {
	root := gitRepo(t)
	slug := "demo-intent"
	acc := "Acceptance:\n- " + FeaturePath(slug) + "\n- features/steps/z.js\n- features/steps/a.js\n- " + ModelPath(slug)
	writeFile(t, root, IntentMDPath(slug), demoMD(demoParts{acc: &acc}))
	writeFile(t, root, FeaturePath(slug), goodFeature)
	writeFile(t, root, ModelPath(slug), "m")
	writeFile(t, root, IntentDir(slug)+"/notes/b.txt", "n")
	writeFile(t, root, IntentDir(slug)+"/.hidden", "h")
	writeFile(t, root, "features/steps/z.js", "z")
	writeFile(t, root, "features/steps/a.js", "a")
	writeFile(t, root, "lint.cfg", "c")
	writeFile(t, root, "other/lint.cfg", "c")
	writeFile(t, root, ConfigPath, Template())
	cfg := &Config{Protect: []string{"lint.cfg", "features/steps/a.js", "nothing-matches"}}
	got, err := Baseline(root, slug, cfg)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		IntentMDPath(slug), FeaturePath(slug), "features/steps/z.js", "features/steps/a.js", ModelPath(slug),
		IntentDir(slug) + "/.hidden", IntentDir(slug) + "/notes/b.txt",
		ConfigPath, "lint.cfg",
	}
	if !slices.Equal(got, want) {
		t.Errorf("baseline\n got %q\nwant %q", got, want)
	}
}

func TestBaselineWithoutIntentFiles(t *testing.T) {
	root := gitRepo(t)
	got, err := Baseline(root, "nothing", &Config{})
	if err != nil || !slices.Equal(got, []string{ConfigPath}) {
		t.Errorf("got %v %v", got, err)
	}
}

func TestApprovalFiles(t *testing.T) {
	root := t.TempDir()
	if got := ApprovalPath(root, "a-b"); got != filepath.Join(root, ".kogen/local/approvals/a-b.json") {
		t.Errorf("path %q", got)
	}
	if a, err := ReadApproval(root, "a-b"); a != nil || err != nil {
		t.Errorf("missing approval: %v %v", a, err)
	}
	in := Approval{
		Slug: "a-b", SHA256: strings.Repeat("ab", 32), Approver: "Ada <ada@example.test>", ApprovedAt: "2026-10-22T12:00:00Z",
		SourceProvenance: map[string]any{"contract_sha256": "x", "note": "a < b & c", "n": float64(3)},
	}
	if err := WriteApproval(root, in); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(ApprovalPath(root, "a-b"))
	if err != nil || !strings.HasSuffix(string(raw), "}\n") || strings.Contains(string(raw), "\\u003c") {
		t.Errorf("raw %q %v", raw, err)
	}
	var fields map[string]any
	if err := json.Unmarshal(raw, &fields); err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{"slug", "sha256", "approver", "approved_at", "source_provenance"} {
		if _, ok := fields[k]; !ok {
			t.Errorf("field %s missing from %s", k, raw)
		}
	}
	if len(fields) != 5 {
		t.Errorf("fields %v", fields)
	}
	out, err := ReadApproval(root, "a-b")
	if err != nil || out.Slug != in.Slug || out.SHA256 != in.SHA256 || out.Approver != in.Approver || out.ApprovedAt != in.ApprovedAt || out.SourceProvenance["note"] != "a < b & c" {
		t.Errorf("read %+v %v", out, err)
	}
	// Written by the Elixir Kogen: the same five fields in another order.
	writeFile(t, root, ".kogen/local/approvals/c-d.json", `{"source_provenance":{"k":1},"approver":"x","sha256":"s","slug":"c-d","approved_at":"t"}`+"\n")
	if a, err := ReadApproval(root, "c-d"); err != nil || a.SHA256 != "s" || a.SourceProvenance["k"] != float64(1) {
		t.Errorf("elixir approval %+v %v", a, err)
	}
	writeFile(t, root, ".kogen/local/approvals/e-f.json", "not json")
	if a, err := ReadApproval(root, "e-f"); a != nil || err == nil {
		t.Errorf("malformed approval: %v %v", a, err)
	}
	writeFile(t, root, ".kogen/local/approvals/g-h.json", `{"slug":"g-h"}`)
	if a, err := ReadApproval(root, "g-h"); err != nil || a.SourceProvenance != nil || a.SHA256 != "" {
		t.Errorf("approval without provenance: %+v %v", a, err)
	}
}

func TestGraphemeLen(t *testing.T) {
	cases := map[string]int{
		"":            0,
		"abc":         3,
		"日本":          2,
		"é":          1,
		"é":           1,
		"👩‍👩‍👧":       1,
		"🇧🇦":          1,
		"🇧🇦🇩🇪":        2,
		"🇧🇦🇩🇪🇫":       3,
		"👍🏽":          1,
		"a\r\nb":      3,
		"한국어":         3,
		"❤️":          1,
		"a‍b":         2,
		"कि":          1,
		"x\U000e0067": 1,
	}
	for s, want := range cases {
		if got := graphemeLen(s); got != want {
			t.Errorf("graphemeLen(%q) = %d, want %d", s, got, want)
		}
	}
}

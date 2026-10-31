package shape

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"kogen/project"
)

func renderExcerpt(t *testing.T, bytes string) (map[string]any, string) {
	t.Helper()
	text := Excerpt("literal/é.txt", ContentHash([]byte(bytes)), bytes, nil)
	header, body, _ := strings.Cut(text, "\n")
	header, ok := strings.CutPrefix(header, "Excerpt: ")
	if !ok {
		t.Fatalf("excerpt = %q", text)
	}
	var h map[string]any
	if err := json.Unmarshal([]byte(header), &h); err != nil {
		t.Fatal(err)
	}
	keys := ""
	for _, k := range sortedKeys(h) {
		keys += k + " "
	}
	shpEq(t, "header keys", keys, "end_line path sha256 start_line ")
	shpEq(t, "header hash", h["sha256"], any(ContentHash([]byte(bytes))))
	return h, body
}

func TestExcerptWindowsPreserveAdjacentLineAndUTF8ByteBounds(t *testing.T) {
	parallel(t)
	// ExUnit: shape_context_test explicit windows preserve adjacent line and UTF-8 byte bounds
	for _, count := range []int{79, 80, 81} {
		var lines []string
		for i := 1; i <= count; i++ {
			lines = append(lines, fmt.Sprintf("line %d", i))
		}
		bytes := strings.Join(lines, "\n")
		h, body := renderExcerpt(t, bytes)
		shpEq(t, "start_line", h["start_line"], any(float64(1)))
		shpEq(t, "end_line", h["end_line"], any(float64(min(count, 80))))
		want := ""
		for _, l := range lines[:min(count, 80)] {
			want += l + "\n"
		}
		shpEq(t, "body", body, want)
	}
	for _, size := range []int{8191, 8192, 8193} {
		// Includes a multibyte codepoint; size includes the rendered newline.
		line := "é" + strings.Repeat("x", size-3)
		h, body := renderExcerpt(t, line)
		if len(body) > 8192 || !strings.HasSuffix(body, "") {
			t.Fatalf("body is %d bytes", len(body))
		}
		want, end := "", 0.0
		if size <= 8192 {
			want, end = line+"\n", 1
		}
		shpEq(t, fmt.Sprint("body at ", size), body, want)
		shpEq(t, fmt.Sprint("end_line at ", size), h["end_line"], any(end))
	}
}

func TestExcerptWindowsDoNotInventALineAfterTheSourceFinalNewline(t *testing.T) {
	parallel(t)
	// ExUnit: shape_context_test explicit windows do not invent a line after the source final newline
	for _, tc := range []struct {
		bytes, want string
		count       float64
	}{
		{"", "", 0}, {"one", "one\n", 1}, {"one\n", "one\n", 1}, {"\n", "\n", 1}, {"one\n\n", "one\n\n", 2},
	} {
		h, body := renderExcerpt(t, tc.bytes)
		shpEq(t, fmt.Sprintf("body of %q", tc.bytes), body, tc.want)
		shpEq(t, "start_line", h["start_line"], any(float64(1)))
		shpEq(t, fmt.Sprintf("end_line of %q", tc.bytes), h["end_line"], any(tc.count))
	}
}

func TestExcerptStartsFiveLinesBeforeTheFirstMatch(t *testing.T) {
	parallel(t)
	var lines []string
	for i := 1; i <= 200; i++ {
		lines = append(lines, fmt.Sprintf("line %d", i))
	}
	lines[119] = "The NEEDLE is here"
	text := Excerpt("a.txt", "h", strings.Join(lines, "\n"), []string{"needle"})
	shpContains(t, "header", text, `"start_line":115`)
	shpContains(t, "header", text, `"end_line":194`)
	shpContains(t, "body", text, "\nline 115\n")
	if got := Excerpt("a.txt", "h", "x\ny\n", []string{"missing"}); !strings.Contains(got, `"start_line":1`) {
		t.Fatalf("without a match the window starts at the top: %s", got)
	}
}

func TestContextIsIndexFirstAndExcerptsRetainExactFrozenProvenance(t *testing.T) {
	parallel(t)
	// ExUnit: shape_dispatch_test context is index-first and explicit excerpts retain exact frozen provenance
	f, sh, _, _ := newBatchValidation(t)
	path := "features/steps/source.js"
	bytes := strings.Repeat("// unrelated prefix\n", 100) + "Then(\n  'the literal needle is {string}',\n  function () {}\n);\n"
	f.write(path, bytes)
	f.write("image.bin", "\x00\xff*")
	originalDir := filepath.Join(f.Root, ".kogen/local/original")
	opts := ContextOptions{Owned: []string{}, OriginalDir: originalDir}
	text, index, err := BuildContextIndex(f.Repo, sh.cfg, shpSlug, map[string][]byte{path: []byte(bytes)}, opts)
	if err != nil {
		t.Fatal(err)
	}
	var entry, ordinary *ContextEntry
	for i := range index.Entries {
		switch index.Entries[i].Path {
		case path:
			entry = &index.Entries[i]
		case "image.bin":
			ordinary = &index.Entries[i]
		}
	}
	if entry == nil || ordinary == nil {
		t.Fatalf("entries = %v", index.Entries)
	}
	shpEq(t, "ownership", entry.Ownership, "shared")
	shpEq(t, "source", entry.Source, filepath.Join(originalDir, path))
	shpEq(t, "hash", entry.SHA256, ContentHash([]byte(bytes)))
	shpContains(t, "text", text, "the literal needle is {string}")
	if strings.Contains(text, "Excerpt: ") {
		t.Fatal("the context carries no automatic excerpts")
	}
	shpEq(t, "root", index.Root, f.Root)
	shpEq(t, "ordinary has no source", ordinary.Source, "")
	shpEq(t, "ordinary ownership", ordinary.Ownership, "source")
	shpEq(t, "ordinary has no signatures", len(ordinary.Signatures), 0)
	excerpt := ExcerptOf(*entry, bytes, []string{"literal needle"})
	shpContains(t, "excerpt", excerpt, `"start_line":97`)
	found := false
	for _, s := range entry.Signatures {
		found = found || (s.StartLine == 101 && s.EndLine == 102)
	}
	if !found {
		t.Fatalf("signatures = %v", entry.Signatures)
	}
	again, _, err := BuildContextIndex(f.Repo, sh.cfg, shpSlug, map[string][]byte{path: []byte(bytes)}, opts)
	if err != nil {
		t.Fatal(err)
	}
	shpEq(t, "the index is deterministic", again, text)
}

func TestContextIndexOwnershipSkipsAndDirectories(t *testing.T) {
	parallel(t)
	f, sh, _, _ := newBatchValidation(t)
	f.write("AGENTS.md", "agents")
	f.write("sub/CLAUDE.md", "claude")
	f.write("sub/a.txt", "a")
	f.write(".kogen/local/secret.txt", "secret")
	f.write(".kogen/intents/is-even/intent.md", shpIntentMD)
	f.write(".kogen/intents/is-even/acceptance.feature", shpFeature)
	f.write("features/steps/is_even_steps.js", shpSteps)
	f.write("other.js", "var a = 1\n// def not a declaration\n  def b(x)\nval c = 2\nmodule M\n")
	text, idx, err := BuildContextIndex(f.Repo, sh.cfg, shpSlug, nil, ContextOptions{})
	if err != nil {
		t.Fatal(err)
	}
	owner := map[string]string{}
	for _, e := range idx.Entries {
		owner[e.Path] = e.Ownership
	}
	shpEq(t, "protected", owner["guard.txt"], "protected")
	shpEq(t, "project config", owner[".kogen/project.yaml"], "source")
	shpEq(t, "listed step", owner["features/steps/is_even_steps.js"], "shared")
	shpEq(t, "step folder", owner["features/steps/calc_steps.js"], "shared")
	shpEq(t, "listed feature", owner[".kogen/intents/is-even/acceptance.feature"], "shared")
	shpEq(t, "plain source", owner["calc.js"], "source")
	for _, skipped := range []string{"AGENTS.md", "sub/CLAUDE.md", ".kogen/local/secret.txt"} {
		if _, ok := owner[skipped]; ok {
			t.Errorf("%s is not indexed", skipped)
		}
	}
	// A file shaping edits is owned.
	_, idx, err = BuildContextIndex(f.Repo, sh.cfg, shpSlug, map[string][]byte{"calc.js": []byte("old")}, ContextOptions{})
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range idx.Entries {
		if e.Path == "calc.js" {
			shpEq(t, "owned", e.Ownership, "editable-owned")
			shpEq(t, "original bytes are indexed", e.SHA256, ContentHash([]byte("old")))
		}
	}
	var sigs []string
	for _, e := range idx.Entries {
		if e.Path == "other.js" {
			for _, s := range e.Signatures {
				sigs = append(sigs, fmt.Sprintf("%d:%s", s.StartLine, s.Text))
			}
		}
	}
	shpEq(t, "declarations", strings.Join(sigs, "|"), "1:var a = 1|3:  def b(x)|4:val c = 2|5:module M")
	shpContains(t, "text", text, `{"count":2,"path":"sub"}`)
	shpContains(t, "text", text, "read_file exact bytes and line ranges; list_files directories; search_text exact signatures")
	included := 0
	for _, s := range idx.Measure.Selection {
		if s.Path == "README.md" {
			included = s.IncludedBodyBytes
			shpEq(t, "README reason", s.Reason, "full authoritative contract; exact instructions/declarations win excerpt budget")
		}
	}
	shpEq(t, "README is the full contract", included, len("# Calc\n\nA tiny calculator.\n"))
	if idx.Measure.Included != included || idx.Measure.Omitted <= 0 {
		t.Fatalf("measure = %+v", idx.Measure)
	}
}

func TestContextIndexPagesLongSignatureLists(t *testing.T) {
	parallel(t)
	f, sh, _, _ := newBatchValidation(t)
	var b strings.Builder
	for i := 0; i < 250; i++ {
		fmt.Fprintf(&b, "val v%d = %d\n", i, i)
	}
	f.write("big.qnt", b.String())
	_, idx, err := BuildContextIndex(f.Repo, sh.cfg, shpSlug, nil, ContextOptions{})
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range idx.Entries {
		if e.Path != "big.qnt" {
			continue
		}
		shpEq(t, "kept signatures", len(e.Signatures), 200)
		if e.SignatureIndex == nil || e.SignatureIndex.Count != 250 {
			t.Fatalf("signature index = %+v", e.SignatureIndex)
		}
		page, err := os.ReadFile(e.SignatureIndex.Source)
		if err != nil || strings.Count(string(page), "\n") != 249 || ContentHash(page) != e.SignatureIndex.SHA256 {
			t.Fatalf("page: %v, %d lines", err, strings.Count(string(page), "\n"))
		}
		shpContains(t, "page", string(page), `{"end_line":1,"start_line":1,"text":"val v0 = 0"}`)
		return
	}
	t.Fatal("big.qnt not indexed")
}

func TestRevisionFollowsTheCheckoutWithoutTouchingTheRealIndex(t *testing.T) {
	serialTmp(t)
	f, _, _, _ := newBatchValidation(t)
	index, _ := os.ReadFile(filepath.Join(f.Root, ".git/index"))
	a, err := CurrentRevision(f.Repo)
	if err != nil {
		t.Fatal(err)
	}
	shpEq(t, "head", a.Head, f.head())
	f.write(".kogen/local/anything.txt", "ignored")
	same, _ := CurrentRevision(f.Repo)
	shpEq(t, ".kogen/local is not part of the revision", same, a)
	f.write("new.txt", "drift")
	b, _ := CurrentRevision(f.Repo)
	if b.Tree == a.Tree || b.Head != a.Head {
		t.Fatalf("a non-ignored untracked file changes the tree only: %+v %+v", a, b)
	}
	after, _ := os.ReadFile(filepath.Join(f.Root, ".git/index"))
	if string(after) != string(index) {
		t.Fatal("the real index is not touched")
	}
	entries, _ := os.ReadDir(f.Tmp)
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), "kogen-context-index") || strings.HasPrefix(e.Name(), "kogen-index") {
			t.Fatalf("left behind: %s", e.Name())
		}
	}
}

func TestContextBlocksCarryTheContractsAndEarlierRounds(t *testing.T) {
	parallel(t)
	f, sh, _, _ := newBatchValidation(t)
	st := &state{Request: "Add calc.is_even(n).", Rounds: []map[string]any{{
		"questions": []any{
			map[string]any{"question": "First?", "options": []any{map[string]any{"label": "yes", "recommended": true}, map[string]any{"label": "no"}}},
			map[string]any{"question": "Free?"},
		},
		"answers": map[string]any{"1": "a", "2": "my words"},
	}}}
	protected, _ := project.Protected(f.Root, sh.cfg)
	blocks, err := contextBlocks(promptInput{root: f.Root, slug: shpSlug, cfg: sh.cfg, state: st, protected: protected, selected: "Context index: {}\n"})
	if err != nil {
		t.Fatal(err)
	}
	shpEq(t, "two blocks", len(blocks), 2)
	stable := blocks[0].(map[string]any)["text"].(string)
	shpEq(t, "dynamic block", blocks[1].(map[string]any)["text"], any("Context index: {}\n"))
	for _, want := range []string{
		"# Request\n\nAdd calc.is_even(n).\n\n# Your earlier questions and the caller's answers (cite them as `(source: answer <n>)` using the numbers of the latest round)\n\nRound 1:\n1. First?\n   a) yes\n   b) no\n   answer: 1: a\n2. Free?\n   answer: 2: my words\n\n# The Intent to write\n\nSlug: is-even\nWrite `.kogen/intents/is-even/intent.md`, `.kogen/intents/is-even/acceptance.feature`, optionally `.kogen/intents/is-even/model.qnt`, and step files under `features/steps/`.\n\n# Project instructions (README.md)\n\n# Calc\n\nA tiny calculator.\n\n\n# Testing rules (docs/testing-rules.md)\n\n",
		"# Configured commands (.kogen/project.yaml)\n\nsetup: []\nfix: []\nchecks: unit: true\nacceptance: ./accept.sh\n  (it runs with KOGEN_ACCEPTANCE_FEATURES set to the Intent's feature path and KOGEN_ACCEPTANCE_REPORT to the report path)\n\n# Protection contract\n\nconfigured protect patterns: [\"guard.txt\"]\npaths currently matched by those patterns: [\"guard.txt\"]\nautomatic baseline: every file in `.kogen/intents/is-even/`, every path listed under the Intent's `Acceptance:` (including step files), and `.kogen/project.yaml`.\nautomatic paths currently present or listed: [\".kogen/project.yaml\"]\nApproval freezes this baseline.",
		"Full contract inclusions: exact request, Q&A, README, testing rules and protection/automatic baseline are authoritative and are not clipped.\n",
	} {
		shpContains(t, "contract block", stable, want)
	}

	// Without rounds there is no Q&A section; without a steps folder the shaper is told so.
	st.Rounds = nil
	cfg := *sh.cfg
	cfg.Acceptance = &project.Acceptance{Run: "x"}
	blocks, _ = contextBlocks(promptInput{root: f.Root, slug: shpSlug, cfg: &cfg, state: st, selected: "x"})
	stable = blocks[0].(map[string]any)["text"].(string)
	shpContains(t, "no rounds", stable, "# Request\n\nAdd calc.is_even(n).\n\n\n# The Intent to write\n")
	shpContains(t, "unset steps folder", stable, "and step files under `(commands.acceptance.steps_dir is unset: you cannot add step files)/`.")
}

func TestInspectStringsMatchesElixir(t *testing.T) {
	parallel(t)
	for _, tc := range []struct {
		in   []string
		want string
	}{
		{nil, "[]"},
		{[]string{"npm ci", "make test"}, `["npm ci", "make test"]`},
		{[]string{`a "q" #{x}`, "é\n\t\\"}, `["a \"q\" \#{x}", "é\n\t\\"]`},
	} {
		shpEq(t, "inspect", InspectStrings(tc.in), tc.want)
	}
	long := make([]string, 60)
	for i := range long {
		long[i] = fmt.Sprintf("tests/some/dir/file_%d.py", i+1)
	}
	got := InspectStrings(long)
	if strings.Contains(got, "\n") || strings.Contains(got, "...") || !strings.HasSuffix(got, `"tests/some/dir/file_60.py"]`) {
		t.Fatalf("long lists stay on one line, whole: %q", got[:80])
	}
}

func TestSubmittedPathsMustBeNormal(t *testing.T) {
	parallel(t)
	for p, want := range map[string]bool{
		"a.js": true, "dir/a.js": true, "a/b/c": true, "": false, "/a": false, "./a": false, "a/./b": false, "a//b": false,
		"a/../b": false, "../a": false, "a/": false, "~": false, "~/a": false, "..": false, "a/..": false, ".hidden": true,
	} {
		if normalPath(p) != want {
			t.Errorf("normalPath(%q) = %v, want %v", p, !want, want)
		}
	}
}

func TestFormatWallPrintsAtLeastOneDecimal(t *testing.T) {
	parallel(t)
	for in, want := range map[float64]string{0: "0.0", 0.1: "0.1", 3: "3.0", 12.5: "12.5", 300: "300.0"} {
		shpEq(t, "wall", formatWall(in), want)
	}
}

func TestShapeCommonHelpers(t *testing.T) {
	parallel(t)
	shpEq(t, "shell quote", ShellQuote("it's"), `'it'\''s'`)
	shpEq(t, "hash", ContentHash([]byte("")), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
	shpEq(t, "no readme", ReadmeText(t.TempDir()), "(no README.md)")
	cfg, err := project.ParseConfig("version: 1\nshape_workers:\n  enabled: true\n  read: {model: a, effort: low}\n  probe: {model: b, effort: low}\n  draft: {model: c, effort: low}\n", "x")
	if err != nil {
		t.Fatal(err)
	}
	roles := ShapeRoles(cfg)
	shpEq(t, "roles with workers", len(roles), 4)
	shpEq(t, "shape role first", roles[0].Model, "gpt-6.1-sol")
	shpEq(t, "worker roles", roles[1].Model+roles[2].Model+roles[3].Model, "abc")
	off, _ := project.ParseConfig("version: 1\n", "x")
	shpEq(t, "roles without workers", len(ShapeRoles(off)), 1)
	shpEq(t, "exit of an unknown error", ExitCode(os.ErrNotExist), 70)
	shpEq(t, "exit of an error", ExitCode(project.RequireIntentDir(t.TempDir(), "x")), 2)
}

// Ports test/kogen/shape_context_test.exs "navigation has fixed shape across empty, small and
// large candidate trees".
func TestNavigationHasFixedShapeAcrossEmptySmallAndLargeCandidateTrees(t *testing.T) {
	parallel(t)
	f, _, _, _ := newBatchValidation(t)
	head := f.head()
	var sizes []int
	var trees []string
	for _, count := range []int{0, 1, 1800} {
		for n := 1; n <= count; n++ {
			f.write(fmt.Sprintf("deep/source/file-%d.ex", n), fmt.Sprintf("def declaration_%d, do: :ok\n", n))
		}
		text, descriptor, err := Navigation(f.Repo)
		if err != nil {
			t.Fatal(err)
		}
		if len(descriptor) != 3 {
			t.Fatalf("descriptor keys %v", descriptor)
		}
		revision, _ := descriptor["revision"].(map[string]any)
		current, err := CurrentRevision(f.Repo)
		if err != nil {
			t.Fatal(err)
		}
		if len(revision) != 2 || descriptor["root"] != f.Root || !reflect.DeepEqual(revision, current.Map()) || revision["head"] != head ||
			descriptor["retrieval"] != "read_file exact bytes and line ranges; list_files directories; search_text exact signatures" {
			t.Fatalf("descriptor %v", descriptor)
		}
		encoded, _ := project.EncodeJSON(descriptor)
		if text != "Context navigation: "+string(encoded)+"\n" || len(strings.Split(text, "\n")) != 2 || len(text) >= 1024 {
			t.Fatalf("text %q", text)
		}
		again, _, _ := Navigation(f.Repo)
		if again != text {
			t.Fatal("navigation is not deterministic")
		}
		sizes = append(sizes, len(encoded))
		trees = append(trees, revision["tree"].(string))
	}
	if sizes[0] != sizes[1] || sizes[1] != sizes[2] || trees[0] == trees[1] || trees[1] == trees[2] || trees[0] == trees[2] {
		t.Fatalf("sizes %v trees %v", sizes, trees)
	}
	_, before, _ := Navigation(f.Repo)
	f.write(".kogen/local/private", "not navigation")
	if _, got, _ := Navigation(f.Repo); !reflect.DeepEqual(got, before) {
		t.Fatalf("private local files changed the navigation: %v", got)
	}
	f.write("deep/source/file-1.ex", "changed candidate")
	_, changed, _ := Navigation(f.Repo)
	if changed["revision"].(map[string]any)["tree"] == before["revision"].(map[string]any)["tree"] || changed["revision"].(map[string]any)["head"] != head {
		t.Fatalf("a changed candidate keeps its tree: %v", changed)
	}
}

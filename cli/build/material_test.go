package build

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"unicode/utf8"

	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen-loop/tools"
	gitpkg "kogen/git"
	"kogen/project"
	"kogen/verify"
)

func sessionOfEnv(env []string, root string) *sys.Session { return sys.NewWith(env, root) }

func materialRole() project.Role { return project.Role{Model: "fixture", Effort: "high"} }

func testMaterial(source string) materialSet {
	return materialSet{
		Authority: "exact approved literal Δ🙂\r\n\t  ",
		Source:    source,
		Checks:    "acceptance: passed (1 scenarios)",
		Files:     []map[string]any{},
	}
}

// materialAttempt is an Attempt at review 1 with a clean checkout for the material tests.
func materialAttempt(t *testing.T) (*Attempt, *env, string) {
	t.Helper()
	b, e, tree := windowAttempt(t)
	b.Review = 1
	b.LastReview = nil
	return b, e, tree
}

func TestSmallSourceRemainsInlineWithoutNewCustody(t *testing.T) {
	t.Parallel()
	// ExUnit: test/integration/review_material_test.exs: small source remains inline without new custody
	b, _, tree := materialAttempt(t)
	m := testMaterial("small source\n")
	diagnostic := []any{map[string]any{"role": "user", "content": "frozen diagnostic\r\nΔ🙂"}}
	input, err := b.materialPrepare(tree, m, materialRole(), "policy", nil, diagnostic, false)
	if err != nil {
		t.Fatal(err)
	}
	want := slicesOf(map[string]any{"role": "user", "content": provider.ContractBlocks(m.Authority, m.Source)}, diagnostic[0])
	if !reflect.DeepEqual(input, want) {
		t.Fatalf("input %v", input)
	}
	// The fitting source stays inline and is remembered, with its tree, to relocate under pressure.
	owner := b.WorkingContext["review"]
	if owner == nil || !reflect.DeepEqual(owner.Mandatory, input) || owner.InlineMaterial == nil || !reflect.DeepEqual(*owner.InlineMaterial, m) ||
		owner.SourceTree == nil || *owner.SourceTree != tree || len(owner.History) != 0 {
		t.Fatalf("working context %+v", owner)
	}
	if _, err := os.Stat(filepath.Join(b.Run.Dir, "review-source")); !os.IsNotExist(err) {
		t.Fatal("source custody was created")
	}
	if unread, err := b.materialUnread(input); err != nil || len(unread) != 0 {
		t.Fatalf("unread %v %v", unread, err)
	}
}

func slicesOf(items ...any) []any { return items }

func TestExactUTF8SourceDeliverySurvivesResetAndDamagedCustodyRefuses(t *testing.T) {
	t.Parallel()
	// ExUnit: test/integration/review_material_test.exs: chatgpt and opencode-go exact UTF8 source delivery survives reset and damaged custody refuses
	for name, role := range map[string]project.Role{
		"chatgpt":     materialRole(),
		"opencode-go": {Provider: "opencode-go", Model: "kimi-k3", Effort: "high"},
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			exactSourceDelivery(t, role)
		})
	}
}

func exactSourceDelivery(t *testing.T, role project.Role) {
	b, _, tree := materialAttempt(t)
	source := strings.Repeat("literal Δ🙂\r\n\t\"\\\u0001", 30_000) + strings.Repeat("\u0001", 12_000)
	m := testMaterial(source)
	input, err := b.materialPrepare(tree, m, role, "policy", nil, nil, false)
	if err != nil {
		t.Fatal(err)
	}
	if fit, err := tools.Measure(b.bodyOf(role, "policy", input, nil, "review")); err != nil || !fit.Fits {
		t.Fatalf("the opening request does not fit: %v %+v", err, fit)
	}
	blocks := input[0].(map[string]any)["content"].([]any)
	eq(t, "authority", blocks[0].(map[string]any)["text"].(string), m.Authority)
	refs := b.WorkingContext["review"].History
	if len(refs) <= 1 {
		t.Fatalf("%d parts", len(refs))
	}
	tl := &tools.Tools{Root: b.Root, Enabled: []string{"read_file"}}
	var exchanges [][]any
	var rebuilt strings.Builder
	for n, ref := range refs {
		data, err := os.ReadFile(ref.Path)
		if err != nil || hashHex(data) != ref.SHA256 {
			t.Fatalf("%s: %v", ref.Path, err)
		}
		if st, _ := os.Stat(ref.Path); st.Mode().Perm() != 0o600 {
			t.Fatalf("part mode %v", st.Mode().Perm())
		}
		if st, _ := os.Stat(filepath.Dir(ref.Path)); st.Mode().Perm() != 0o700 {
			t.Fatalf("part folder mode %v", st.Mode().Perm())
		}
		out, err := tl.Run("read_file", map[string]any{"path": ref.Path})
		if err != nil {
			t.Fatal(err)
		}
		if out.Cut().Text != out.Text {
			t.Fatalf("part %d is cut by the read tool", n+1)
		}
		var doc struct {
			ReviewSource struct {
				Review, Part, Parts int
				Text                string
			} `json:"review_source"`
		}
		if err := json.Unmarshal(data, &doc); err != nil || doc.ReviewSource.Part != n+1 || doc.ReviewSource.Parts != len(refs) {
			t.Fatalf("part %d: %v %+v", n+1, err, doc)
		}
		rebuilt.WriteString(doc.ReviewSource.Text)
		id := fmt.Sprintf("read-%d", n)
		exchanges = append(exchanges, []any{
			map[string]any{"type": "function_call", "call_id": id, "name": "read_file", "arguments": jsonText(map[string]any{"path": ref.Path})},
			map[string]any{"type": "function_call_output", "call_id": id, "output": out.Text},
		})
	}
	eq(t, "concatenated parts", rebuilt.String(), source)

	unread := func(input []any) int {
		t.Helper()
		u, err := b.materialUnread(input)
		if err != nil {
			t.Fatal(err)
		}
		return len(u)
	}
	eq(t, "unread before any read", unread(input), len(refs))
	call, result := exchanges[0][0].(map[string]any), exchanges[0][1].(map[string]any)
	bad := func(o map[string]any) map[string]any {
		c := map[string]any{}
		for k, v := range result {
			c[k] = v
		}
		for k, v := range o {
			c[k] = v
		}
		return c
	}
	for name, extra := range map[string][]any{
		"a call without its result": {call},
		"a clipped result":          {call, bad(map[string]any{"output": "truncated"})},
		"a result of another call":  {call, bad(map[string]any{"call_id": "wrong"})},
	} {
		if n := unread(append(append([]any{}, input...), extra...)); n != len(refs) {
			t.Fatalf("%s counts as delivery: %d unread", name, n)
		}
	}
	var complete []any
	complete = append(complete, input...)
	for _, ex := range exchanges {
		complete = append(complete, ex...)
	}
	eq(t, "unread after complete delivery", unread(complete), 0)

	// A reset archives the exchanges; delivery stays provable through the exact archives.
	active, err := b.prepareContext("review", role, "policy", complete, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(active) >= len(complete) {
		t.Fatalf("no reset: %d items", len(active))
	}
	eq(t, "unread after the reset", unread(active), 0)
	if err := b.validateWorkingContext(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(refs[0].Path, []byte("changed"), 0o600); err != nil {
		t.Fatal(err)
	}
	err = b.validateWorkingContext()
	if err == nil || !strings.Contains(err.Error(), "history custody") || !strings.Contains(err.Error(), "changed") {
		t.Fatalf("damaged custody: %v", err)
	}
}

func TestIrreducibleReviewAuthorityRefusesWithoutFilesOrIndexChanges(t *testing.T) {
	t.Parallel()
	// ExUnit: test/integration/review_material_test.exs: irreducible authority refuses without files or index changes
	b, e, tree := materialAttempt(t)
	m := testMaterial(strings.Repeat("source", 120_000))
	m.Authority = strings.Repeat("authority", 70_000)
	index := e.state()["index"]
	_, err := b.materialPrepare(tree, m, materialRole(), "policy", nil, nil, false)
	if err == nil {
		t.Fatal("irreducible authority accepted")
	}
	for _, part := range []string{"candidate/context_budget_exceeded: review: mandatory authority/catalog ", "ceiling 524288", "output reserve 131072 tokens", "checkpoint", "ordinary Refine and new exact approval"} {
		contains(t, "error", err.Error(), part)
	}
	eq(t, "index", e.state()["index"], index)
	if _, err := os.Stat(filepath.Join(b.Run.Dir, "review-source")); !os.IsNotExist(err) {
		t.Fatal("source custody was created")
	}
	if len(b.WorkingContext) != 0 {
		t.Fatalf("working context %v", b.WorkingContext)
	}
}

func TestSourceIsSplitInOrderWithoutLosingAByteOrBreakingAnEncoding(t *testing.T) {
	t.Parallel()
	// ExUnit: test/integration/review_material_test.exs: exact UTF8 source delivery survives reset and damaged custody refuses (the split)
	for name, text := range map[string]string{
		"ascii":     strings.Repeat("0123456789\n", 3000),
		"multibyte": strings.Repeat("Δ🙂é", 5000),
		"controls":  strings.Repeat("\u0001\u0002\"\\", 4000),
		"one rune":  "🙂",
	} {
		parts := materialChunks(text)
		eq(t, name+" joined", strings.Join(parts, ""), text)
		for i, p := range parts {
			raw, _ := encodeJSON(p)
			if p == "" || len(p) > materialPartBytes || len(raw) > materialPartJSON || !utf8.ValidString(p) {
				t.Fatalf("%s part %d: %d bytes, %d encoded", name, i, len(p), len(raw))
			}
		}
	}
	if len(materialChunks("")) != 0 {
		t.Fatal("empty text has parts")
	}
}

// materialGolden is testdata/review/material-golden.json, written by testdata/gen/review.exs
// from the Elixir Kogen's `Review.material/2` and `ReviewMaterial.prepare/7`.
type materialGolden struct {
	Start     string           `json:"start"`
	Tree      string           `json:"tree"`
	Gitlink   string           `json:"gitlink"`
	Authority string           `json:"authority"`
	Source    string           `json:"source"`
	Checks    string           `json:"checks"`
	Files     []map[string]any `json:"files"`
	Prepared  struct {
		Input      any    `json:"input"`
		Dir        string `json:"dir"`
		Parts      []struct{ SHA256 string }
		FirstPart  string `json:"first_part"`
		LastPart   string `json:"last_part"`
		SourceHash string `json:"source_sha256"`
	} `json:"prepared"`
}

func TestTheMaterialEqualsTheElixirReference(t *testing.T) {
	t.Parallel()
	// ExUnit: lib/kogen/review.ex material/2 and lib/kogen/review_material.ex prepare/7, replayed through the reference code (testdata/gen/review.exs)
	raw, err := os.ReadFile("testdata/review/material-golden.json")
	if err != nil {
		t.Fatal(err)
	}
	var golden materialGolden
	if err := json.Unmarshal(raw, &golden); err != nil {
		t.Fatal(err)
	}

	root := physical(t, t.TempDir())
	genv := isolatedEnv("GIT_AUTHOR_NAME=x", "GIT_AUTHOR_EMAIL=x@example.invalid", "GIT_COMMITTER_NAME=x", "GIT_COMMITTER_EMAIL=x@example.invalid",
		"GIT_AUTHOR_DATE=2026-10-22T00:00:00Z", "GIT_COMMITTER_DATE=2026-10-22T00:00:00Z")
	git := func(dir string, args ...string) string {
		t.Helper()
		cmd := exec.Command("git", append([]string{"-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false"}, args...)...)
		cmd.Dir, cmd.Env = dir, genv
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
		return strings.TrimSpace(string(out))
	}
	write := func(path, content string, mode os.FileMode) {
		writeFile(t, filepath.Join(root, path), content, mode)
	}
	git(root, "init", "-q")
	write("README.md", "# Gen project\nΔ🙂 readme\n", 0o644)
	write("app.txt", "line one\nold marker\nline three\n", 0o644)
	write("gone.txt", "to be deleted\n", 0o644)
	write("keep.txt", "unchanged\n", 0o644)
	write(".gitignore", ".kogen/local/\n", 0o644)
	git(root, "add", ".")
	git(root, "commit", "-qm", "base")
	start := git(root, "rev-parse", "HEAD")

	write("app.txt", "line one\nnew marker\nline three\n", 0o644)
	os.Remove(filepath.Join(root, "gone.txt"))
	write("new.txt", "added Δ🙂 text\r\nsecond \"line\"\n", 0o644)
	write("new.bin", "\x00\x01\x02\xff", 0o644)
	write("tool.sh", "#!/bin/sh\necho tool\n", 0o755)
	git(root, "init", "-q", "sub")
	git(filepath.Join(root, "sub"), "commit", "--allow-empty", "-qm", "Nested fixture")
	eq(t, "gitlink commit", git(filepath.Join(root, "sub"), "rev-parse", "HEAD"), golden.Gitlink)
	write(".kogen/intents/fixture/acceptance.feature", "Feature: Gen\n  Scenario: One\n    Then it holds\n", 0o644)
	write(".kogen/intents/fixture/model.qnt", "module m { val x = 1 }\n", 0o644)

	run, err := StartRun(root)
	if err != nil {
		t.Fatal(err)
	}
	repo := gitpkg.New(root, genv)
	tree, err := repo.Tree(start, nil)
	if err != nil {
		t.Fatal(err)
	}
	eq(t, "candidate tree", tree, golden.Tree)
	b := &Attempt{
		State: State{
			Root: root, Slug: "fixture", Start: start, Excluded: []string{}, Run: run, Review: 1,
			Baseline: []string{".kogen/intents/fixture/acceptance.feature", ".kogen/project.yaml"},
			Config: &project.Config{Fix: []string{"fmt", "lint --fix"}, Checks: []project.Check{{Name: "tidy", Run: "make tidy"}, {Name: "unit", Run: "make unit"}},
				Acceptance: &project.Acceptance{Run: "npx cucumber"}},
			WorkingContext: map[string]*OwnerContext{}, Continuation: Continuation{Stage: StageReview},
			ApprovalBytes: encodeBase64([]byte(`{"sha256":"exact approval"}`)),
		},
		deps: Deps{Client: &provider.Client{Cache: provider.NewCache(nil)}}, repo: repo, s: sessionOfEnv(genv, root),
		intent: &project.Intent{Text: "# Gen intent\n\nSlug: fixture\n\nDo the thing.\n"},
	}
	pass := verify.Pass{Tree: tree, Model: verify.ModelNone, Acceptance: &verify.Acceptance{Scenarios: make([]verify.ScenarioResult, 1)},
		Checks: []verify.CommandResult{{Name: "tidy"}, {Name: "unit"}}}
	m, err := b.materialOf(pass)
	if err != nil {
		t.Fatal(err)
	}
	mask := func(text string) string {
		text = strings.ReplaceAll(text, root, "<ROOT>")
		text = strings.ReplaceAll(text, run.ID, "abcd1234")
		text = strings.ReplaceAll(text, start, "<START>")
		return strings.ReplaceAll(text, short(start), "<START8>")
	}
	eq(t, "authority", m.Authority, golden.Authority)
	eq(t, "source", mask(m.Source), golden.Source)
	eq(t, "checks", m.Checks, golden.Checks)
	canon := func(v any) string {
		t.Helper()
		b, err := encodeJSON(v)
		if err != nil {
			t.Fatal(err)
		}
		var back any
		if err := json.Unmarshal(b, &back); err != nil {
			t.Fatal(err)
		}
		out, _ := encodeJSON(back)
		return string(out)
	}
	eq(t, "files", canon(m.Files), canon(golden.Files))

	// The same oversize source as the reference's: the catalog, the parts and their bytes.
	source := strings.Repeat("literal Δ🙂\r\n\t\"\\\u0001é€", 24_000) + strings.Repeat("\u0001", 12_000)
	big := materialSet{Authority: "exact approved literal Δ🙂\r\n\t  ", Source: source, Checks: "acceptance: passed (1 scenarios)", Files: m.Files}
	diagnostic := []any{map[string]any{"role": "user", "content": "frozen diagnostic\r\nΔ🙂"}}
	input, err := b.materialPrepare(tree, big, project.Role{Model: "gpt-6.1-sol", Effort: "high"}, "policy", nil, diagnostic, false)
	if err != nil {
		t.Fatal(err)
	}
	eq(t, "opening input", mask(canon(input)), canon(golden.Prepared.Input))
	refs := b.WorkingContext["review"].History
	if len(refs) != len(golden.Prepared.Parts) {
		t.Fatalf("%d parts, reference %d", len(refs), len(golden.Prepared.Parts))
	}
	for i, ref := range refs {
		eq(t, "part sha256", ref.SHA256, golden.Prepared.Parts[i].SHA256)
	}
	eq(t, "part folder", mask(filepath.Dir(refs[0].Path)), golden.Prepared.Dir)
	for path, want := range map[string]string{refs[0].Path: golden.Prepared.FirstPart, refs[len(refs)-1].Path: golden.Prepared.LastPart} {
		got, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		eq(t, "part bytes", string(got), want)
	}
	eq(t, "source sha256", hashHex([]byte(source)), golden.Prepared.SourceHash)
}

func TestFittedInlineSourceRelocatesOnPressure(t *testing.T) {
	t.Parallel()
	// ExUnit: test/integration/review_material_test.exs: fitted inline source relocates on pressure (historical=false and historical=true)
	for _, historical := range []bool{false, true} {
		name := "bound to its tree"
		if historical {
			name = "historical"
		}
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			b, e, tree := materialAttempt(t)
			source := "# Check results of the final pass\nacceptance: passed (1 scenarios)\n# Diff of existing/deleted paths\n" +
				strings.Repeat("candidate source Δ🙂\r\n", 15_000)
			files := []map[string]any{{
				"path": "app.txt", "status": "changed", "mode": "100644", "git_object": e.gitOut("rev-parse", "HEAD:app.txt"),
				"bytes": float64(9), "sha256": hashHex([]byte("baseline\n")),
			}}
			m := testMaterial(source)
			m.Files = files
			diagnostic := []any{map[string]any{"role": "user", "content": "frozen diagnostic Δ\r\n"}}
			input, err := b.materialPrepare(tree, m, materialRole(), "policy", nil, diagnostic, false)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := os.Stat(filepath.Join(b.Run.Dir, "review-source")); !os.IsNotExist(err) {
				t.Fatal("custody was created for a fitting source")
			}
			saved := b.WorkingContext["review"]
			// Without pressure nothing moves.
			same, err := b.prepareContext("review", materialRole(), "policy", input, nil)
			if err != nil || !reflect.DeepEqual(same, input) || b.WorkingContext["review"] != saved || len(saved.History) != 0 {
				t.Fatalf("an unpressured request changed: %v", err)
			}
			exchange := []any{
				map[string]any{"type": "function_call", "name": "read_file", "call_id": "large", "arguments": "{}"},
				map[string]any{"type": "function_call_output", "call_id": "large", "output": strings.Repeat("x", 220_000)},
			}
			if historical {
				saved.InlineMaterial, saved.SourceTree = nil, nil
			}
			active, err := b.prepareContext("review", materialRole(), "policy", slicesOf(append(append([]any{}, input...), exchange...)...), nil)
			if err != nil {
				t.Fatal(err)
			}
			var rebuilt strings.Builder
			parts := 0
			for _, ref := range b.WorkingContext["review"].History {
				data, err := os.ReadFile(ref.Path)
				if err != nil {
					t.Fatal(err)
				}
				var doc struct {
					ReviewSource *struct{ Text string } `json:"review_source"`
				}
				if json.Unmarshal(data, &doc) == nil && doc.ReviewSource != nil {
					rebuilt.WriteString(doc.ReviewSource.Text)
					parts++
				}
			}
			eq(t, "pinned source", rebuilt.String(), source)
			blocks := active[0].(map[string]any)["content"].([]any)
			eq(t, "authority", blocks[0].(map[string]any)["text"].(string), m.Authority)
			contains(t, "active", jsonText(active), m.Checks)
			if fit, err := tools.Measure(b.bodyOf(materialRole(), "policy", active, nil, "review")); err != nil || !fit.Fits {
				t.Fatalf("does not fit: %v %+v", err, fit)
			}
			if unread, err := b.materialUnread(active); err != nil || len(unread) != parts {
				t.Fatalf("unread %v %v, want %d", unread, err, parts)
			}
			eq(t, "diagnostic kept", active[1], diagnostic[0])
			text := blocks[1].(map[string]any)["text"].(string)
			var line string
			for _, l := range strings.Split(text, "\n") {
				if strings.HasPrefix(l, `{"`) {
					line = l
				}
			}
			var catalog map[string]any
			if err := json.Unmarshal([]byte(line), &catalog); err != nil {
				t.Fatal(err)
			}
			eq(t, "source bytes", catalog["source_bytes"], any(float64(len(source))))
			eq(t, "source sha", catalog["source_sha256"], any(hashHex([]byte(source))))
			eq(t, "start head", catalog["start_head"], any(b.Start))
			if historical {
				eq(t, "tree", catalog["candidate_tree"], nil)
				contains(t, "binding", catalog["binding"].(string), "historical")
				if !strings.Contains(b.WorkingContext["review"].History[0].Path, "review-source/1-historical/") {
					t.Fatalf("path %s", b.WorkingContext["review"].History[0].Path)
				}
			} else {
				eq(t, "tree", catalog["candidate_tree"], any(tree))
				eq(t, "binding", catalog["binding"], any("candidate"))
				eq(t, "files", canonical(catalog["files"]), canonical(files))
			}
			// Relocation is a one-time transition, not repeated pinning.
			before := b.WorkingContext["review"].History
			if err := b.materialRelocate(materialRole(), "policy", nil); err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(b.WorkingContext["review"].History, before) || b.WorkingContext["review"].InlineMaterial != nil {
				t.Fatal("the source was pinned twice")
			}
		})
	}
}

func TestOnDemandManifestHasDiffStatHunksAndCovers(t *testing.T) {
	t.Parallel()
	b, e, _ := materialAttempt(t)
	e.write("app.txt", "x\n"+strings.Repeat("0123456789abcdef-line\n", 400))
	e.write("extra.txt", "one\ntwo\nthree\n")
	tree, err := b.repo.Tree(b.Start, nil)
	if err != nil {
		t.Fatal(err)
	}
	diff, err := b.repo.Diff(b.Start, tree, []string{"app.txt"})
	if err != nil {
		t.Fatal(err)
	}
	app := e.read("app.txt")
	source := "# Check results\n\n# Diff of existing/deleted paths against start HEAD\n\n" + diff +
		"\n# Full text of every changed or added file\n\n--- app.txt\n" + app + "\n--- extra.txt (added; mode 100644)\none\ntwo\nthree\n\n--- gone.txt (deleted)\n"
	catalog := []map[string]any{
		{"path": "app.txt", "status": "changed", "mode": "100644"},
		{"path": "extra.txt", "status": "added", "mode": "100644"},
		{"path": "gone.txt", "status": "deleted", "mode": "100644"},
	}
	texts := []materialFileText{{"app.txt", "--- app.txt\n", app}, {"extra.txt", "--- extra.txt (added; mode 100644)\n", "one\ntwo\nthree\n"}}
	manifest, segments, _, err := b.materialManifest(tree, catalog, texts, source)
	if err != nil {
		t.Fatal(err)
	}
	if len(manifest) != 3 {
		t.Fatalf("manifest %v", manifest)
	}
	stat := manifest[0]["diff_stat"].(map[string]any)
	if stat["added"] != 401 || stat["deleted"] != strings.Count(diff, "\n-")-1 {
		t.Errorf("app.txt stat %v\n%s", stat, diff[:200])
	}
	hunks := manifest[0]["hunks"].([]map[string]any)
	if len(hunks) != 1 || hunks[0]["new_start"] != 1 || hunks[0]["new_count"] != 401 || !strings.HasPrefix(hunks[0]["header"].(string), "@@ -") {
		t.Errorf("app.txt hunks %v", hunks)
	}
	added := manifest[1]["hunks"].([]map[string]any)
	if !reflect.DeepEqual(added, []map[string]any{{"old_start": 0, "old_count": 0, "new_start": 1, "new_count": 3, "header": "@@ -0,0 +1,3 @@"}}) ||
		manifest[1]["diff_stat"].(map[string]any)["added"] != 3 {
		t.Errorf("added %v", manifest[1])
	}
	if d := manifest[2]["diff_stat"].(map[string]any); d["added"] != 0 || d["deleted"] != 0 || len(manifest[2]["hunks"].([]map[string]any)) != 0 {
		t.Errorf("deleted %v", manifest[2])
	}
	// The whole source is one part: the file text is covered from line 1 to its last line.
	covers := materialCovers(materialSet{Source: source, Segments: segments}, 0, len(source))
	var file map[string]any
	for _, c := range covers {
		if c["path"] == "app.txt" && c["kind"] == "file" {
			file = c
		}
	}
	if file == nil || file["first_line"] != 1 || file["last_line"] != 401 {
		t.Errorf("covers %v", covers)
	}
	// A part that starts inside the file text starts on the line holding its first byte.
	mid := strings.Index(source, "--- app.txt\n") + len("--- app.txt\n") + len("x\n") + 22 + 5
	covers = materialCovers(materialSet{Source: source, Segments: segments}, mid, len(source))
	for _, c := range covers {
		if c["path"] == "app.txt" && c["kind"] == "file" && c["first_line"] != 3 {
			t.Errorf("mid cover %v", c)
		}
	}
}

func TestOnDemandManifestCoversADeletedPathsDiffBlock(t *testing.T) {
	t.Parallel()
	b, e, _ := materialAttempt(t)
	if err := os.Remove(filepath.Join(e.root, "app.txt")); err != nil {
		t.Fatal(err)
	}
	tree, err := b.repo.Tree(b.Start, nil)
	if err != nil {
		t.Fatal(err)
	}
	diff, err := b.repo.Diff(b.Start, tree, []string{"app.txt"})
	if err != nil || diff == "" {
		t.Fatalf("diff %q %v", diff, err)
	}
	source := "# Diff of existing/deleted paths against start HEAD\n\n" + diff +
		"\n# Full text of every changed or added file\n\n--- app.txt (deleted)\n"
	catalog := []map[string]any{{"path": "app.txt", "status": "deleted", "mode": "100644"}}
	manifest, segments, _, err := b.materialManifest(tree, catalog, nil, source)
	if err != nil {
		t.Fatal(err)
	}
	if d := manifest[0]["diff_stat"].(map[string]any); d["added"] != 0 || d["deleted"] != 0 || len(manifest[0]["hunks"].([]map[string]any)) != 0 {
		t.Errorf("deleted %v", manifest[0])
	}
	covers := materialCovers(materialSet{Source: source, Segments: segments}, 0, len(source))
	want := []map[string]any{{"path": "app.txt", "kind": "diff", "first_line": 1, "last_line": strings.Count(diff, "\n")}}
	if !reflect.DeepEqual(covers, want) {
		t.Errorf("covers %v, want %v", covers, want)
	}
}

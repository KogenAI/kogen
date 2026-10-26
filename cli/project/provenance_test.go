package project

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"kogen-loop/sys"
)

// provenanceFixture builds the repository testdata/facts-gen.exs built for the Elixir Kogen:
// the same files, one commit with fixed identities and dates (so the commit and tree ids are
// those Elixir computed), then the untracked files.
func provenanceFixture(t *testing.T, g *factsGolden) string {
	t.Helper()
	root := gitRepo(t)
	for k, v := range map[string]string{
		"GIT_AUTHOR_NAME": "Kogen Test", "GIT_AUTHOR_EMAIL": "kogen-test@example.test",
		"GIT_COMMITTER_NAME": "Kogen Test", "GIT_COMMITTER_EMAIL": "kogen-test@example.test",
		"GIT_AUTHOR_DATE": "2026-01-01T00:00:00Z", "GIT_COMMITTER_DATE": "2026-01-01T00:00:00Z",
	} {
		t.Setenv(k, v)
	}
	for p, c := range g.Repo.Files {
		writeFile(t, root, p, c)
	}
	git(t, root, "add", "-A")
	git(t, root, "commit", "-q", "-m", "fixture")
	for p, c := range g.Repo.Untracked {
		writeFile(t, root, p, c)
	}
	return root
}

func shapeSource(g *factsGolden) ShapeSource {
	return ShapeSource{
		Request:    g.Repo.State.Request,
		SourcePath: g.Repo.State.SourcePath,
		Rounds:     g.Repo.State.Rounds,
		Origin:     g.Repo.State.Origin,
	}
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func sourceErr(t *testing.T, err error, wantInDetail string) {
	t.Helper()
	se, ok := sys.AsError(err)
	if !ok || se.Class != "candidate" || se.Reason != "source_provenance_changed" || se.Exit != 1 ||
		!strings.HasPrefix(se.Detail, "source provenance custody missing, changed or unsafe: ") ||
		!strings.HasSuffix(se.Detail, "; restore the named exact custody from preserved native receipt history, then run the card; if unavailable, stop") ||
		!strings.Contains(se.Detail, wantInDetail) {
		t.Fatalf("got %#v (%v), want candidate/source_provenance_changed mentioning %q", err, err, wantInDetail)
	}
}

const publishText = "  Δ🙂\r\n/private path/診断.txt\n  "

func publishDoc(contract, comparison string) map[string]any {
	return map[string]any{
		"version":         json.Number("1"),
		"request":         NewSourceRequest(publishText, "-"),
		"rounds":          []any{},
		"corrections":     []any{},
		"contract_sha256": contract,
		"comparison":      comparison,
	}
}

func TestSourcePublicationIsPrivateHashBoundAndPreservesPredecessors(t *testing.T) {
	// ExUnit: successful source publication is private, hash bound and preserves immutable predecessors
	root := t.TempDir()
	doc := publishDoc("contract", "omitted: exact literal; Refine and new approval required")
	if err := PublishSource(root, "example", doc); err != nil {
		t.Fatal(err)
	}
	path := SourcePath(root, "example")
	original := readFile(t, path)
	var decoded struct{ Request SourceRequest }
	if err := json.Unmarshal([]byte(original), &decoded); err != nil || decoded.Request.Text != publishText {
		t.Fatalf("receipt text %q (%v)", decoded.Request.Text, err)
	}
	mode := func(p string) os.FileMode {
		t.Helper()
		fi, err := os.Stat(p)
		if err != nil {
			t.Fatal(err)
		}
		return fi.Mode().Perm()
	}
	if mode(path) != 0o600 || mode(filepath.Dir(path)) != 0o700 || mode(filepath.Dir(filepath.Dir(path))) != 0o700 {
		t.Errorf("modes: file %o, folder %o, provenance %o", mode(path), mode(filepath.Dir(path)), mode(filepath.Dir(filepath.Dir(path))))
	}
	ref, err := BindSource(root, "example")
	if err != nil {
		t.Fatal(err)
	}
	if ref == nil || ref.SHA256 != sha256Of(original) || ref.Path != path || ref.ContractSHA256 != "contract" {
		t.Fatalf("binding %+v", ref)
	}
	if err := ValidateSource(ref); err != nil {
		t.Fatal(err)
	}
	card, err := SourceCard(ref)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(card, doc["comparison"].(string)) || strings.Contains(card, publishText) {
		t.Errorf("card %q", card)
	}

	if err := PublishSource(root, "example", publishDoc("contract", "addressed: settled literal")); err != nil {
		t.Fatal(err)
	}
	archive := filepath.Join(filepath.Dir(path), sha256Of(original)+".json")
	if readFile(t, archive) != original || mode(archive) != 0o600 {
		t.Errorf("the replaced receipt is not kept intact and private at %s", archive)
	}
	sourceErr(t, ValidateSource(ref), "")

	// A damaged predecessor refuses the next publication and changes nothing.
	current := readFile(t, path)
	damaged := filepath.Join(filepath.Dir(path), sha256Of(current)+".json")
	if err := os.WriteFile(damaged, []byte("damaged predecessor"), 0o600); err != nil {
		t.Fatal(err)
	}
	sourceErr(t, PublishSource(root, "example", doc), damaged)
	if readFile(t, path) != current || readFile(t, damaged) != "damaged predecessor" {
		t.Error("a refused publication changed files")
	}

	bound, err := BindSource(root, "example")
	if err != nil {
		t.Fatal(err)
	}
	local := filepath.Join(root, ".kogen/local")
	if err := os.Rename(local, local+"-moved"); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(local+"-moved", local); err != nil {
		t.Fatal(err)
	}
	sourceErr(t, ValidateSource(bound), "unsafe")
	if err := os.Remove(local); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(local+"-moved", local); err != nil {
		t.Fatal(err)
	}

	if err := os.Chmod(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	sourceErr(t, ValidateSource(bound), "unsafe")
	if err := os.Chmod(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	sourceErr(t, ValidateSource(bound), "missing")
	if legacy, err := BindSource(root, "legacy"); legacy != nil || err != nil {
		t.Errorf("an Intent without a receipt binds to nothing: %v, %v", legacy, err)
	}
	if got := SourceMessage(nil); got != "Source provenance: unavailable (legacy)" {
		t.Errorf("message %q", got)
	}
}

func TestSourceComparisonCopiedCompletelyAtByteBoundary(t *testing.T) {
	// ExUnit: source comparison is copied completely at its UTF-8 byte boundary, never silently clipped
	root := t.TempDir()
	path := filepath.Join(root, IntentMDPath("example"))
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	prefix := "omitted: Δ🙂 "
	for _, size := range []int{8191, 8192} {
		report := prefix + strings.Repeat("x", size-len(prefix))
		if err := os.WriteFile(path, []byte("# Example\n\n## Source comparison\n"+report+"\n\n## Tests\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		got, err := SourceComparison(root, "example")
		if err != nil || got != report {
			t.Errorf("size %d: %d bytes, %v", size, len(got), err)
		}
	}
	for _, body := range []string{"# Missing\n", "## Source comparison\n\n## Tests\n", "## Source comparison\n" + strings.Repeat("x", 8193)} {
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		_, err := SourceComparison(root, "example")
		if se, ok := sys.AsError(err); !ok || !strings.Contains(se.Detail, "Source comparison") {
			t.Errorf("%.30q: %v", body, err)
		}
	}
}

func TestSourceComparisonMatchesElixir(t *testing.T) {
	g := loadFactsGolden(t)
	root := t.TempDir()
	path := filepath.Join(root, IntentMDPath("ex"))
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, c := range g.Comparison {
		if err := os.WriteFile(path, []byte(c.Text), 0o644); err != nil {
			t.Fatal(err)
		}
		got, err := SourceComparison(root, "ex")
		if c.Result.Ok != nil {
			if err != nil || got != *c.Result.Ok {
				t.Errorf("%.50q = %.50q, %v; want %.50q", c.Text, got, err, *c.Result.Ok)
			}
			continue
		}
		want := c.Result.Error
		se, ok := sys.AsError(err)
		if !ok || se.Class != want.Class || se.Reason != want.Reason || se.Detail != want.Detail || se.Exit != want.Exit || len(se.Lines) != 0 {
			t.Errorf("%.50q: %#v, want %+v", c.Text, err, want)
		}
	}
	if _, err := SourceComparison(root, "absent"); err == nil {
		t.Error("an Intent without intent.md has no comparison")
	}
}

func TestConfigDigestMatchesElixirTermToBinary(t *testing.T) {
	g := loadFactsGolden(t)
	if len(g.ConfigDigests) < 12 {
		t.Fatalf("only %d pinned digests", len(g.ConfigDigests))
	}
	seen := map[string]bool{}
	for _, c := range g.ConfigDigests {
		cfg := mustParse(t, c.Text)
		if got := configDigest(cfg); got != c.Digest {
			t.Errorf("%.80q: %s, want %s", c.Text, got, c.Digest)
		}
		seen[c.Digest] = true
	}
	if len(seen) < 10 {
		t.Errorf("the pinned configurations hash to only %d different digests", len(seen))
	}
}

func TestCaptureSourceMatchesElixirFileForFile(t *testing.T) {
	g := loadFactsGolden(t)
	root := provenanceFixture(t, g)
	cfg, err := LoadConfig(root)
	if err != nil {
		t.Fatal(err)
	}
	slug := g.Repo.Slug

	origin, err := CaptureOrigin(root, cfg)
	if err != nil {
		t.Fatal(err)
	}
	if origin != g.Repo.State.Origin || origin.Head != g.Repo.Head {
		t.Fatalf("origin %+v, Elixir %+v", origin, g.Repo.State.Origin)
	}

	if err := CaptureSource(root, slug, cfg, shapeSource(g)); err != nil {
		t.Fatal(err)
	}
	path := SourcePath(root, slug)
	if got := readFile(t, path); got != g.Repo.Captured {
		t.Fatalf("receipt\n got %s\nwant %s", got, g.Repo.Captured)
	}
	if paths, _ := Baseline(root, slug, cfg); Hash(root, paths) != g.Repo.ContractSHA256 {
		t.Errorf("contract hash differs from Elixir's")
	}

	// Refine: the old receipt is archived, the correction appended, comparison and contract
	// replaced; twice.
	ref, err := BindSource(root, slug)
	if err != nil || ref == nil {
		t.Fatalf("bind: %v, %v", ref, err)
	}
	intentMD := filepath.Join(root, IntentMDPath(slug))
	edit := func(f func(string) string) {
		t.Helper()
		if err := os.WriteFile(intentMD, []byte(f(readFile(t, intentMD))), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	edit(func(s string) string {
		return strings.Replace(s, "addressed: request 1", "addressed: requests 1 and 2", 1)
	})
	correction := NewSourceRequest("make it faster\n", "corr.txt")
	if correction != g.Repo.Refine.Correction {
		t.Fatalf("correction %+v, Elixir %+v", correction, g.Repo.Refine.Correction)
	}
	if _, err := RefineSource(root, slug, correction, g.Repo.ContractSHA256, ref); err != nil {
		t.Fatal(err)
	}
	// Elixir wrote its receipts under its own temporary root, which `previous_receipt` names:
	// the same bytes with this root in its place.
	elixirPath, _ := g.Repo.Refine.Ref["path"].(string)
	elixirRoot := strings.TrimSuffix(elixirPath, "/"+filepath.ToSlash(strings.TrimPrefix(SourcePath("", slug), "/")))
	if elixirRoot == elixirPath {
		t.Fatalf("cannot find Elixir's root in %q", elixirPath)
	}
	here := func(s string) string { return strings.ReplaceAll(s, elixirRoot, root) }
	refinedOnce := readFile(t, path)
	if want := here(g.Repo.Refine.Refined); refinedOnce != want {
		t.Fatalf("refined receipt\n got %s\nwant %s", refinedOnce, want)
	}
	dir := filepath.Dir(path)
	entries, _ := os.ReadDir(dir)
	files, modes := map[string]string{}, map[string]int{}
	for _, e := range entries {
		files[e.Name()] = readFile(t, filepath.Join(dir, e.Name()))
		fi, _ := e.Info()
		modes[e.Name()] = int(fi.Mode().Perm())
	}
	wantFiles := map[string]string{}
	for name, content := range g.Repo.Refine.DirFiles {
		wantFiles[name] = here(content)
	}
	if !reflect.DeepEqual(files, wantFiles) || !reflect.DeepEqual(modes, g.Repo.Refine.DirModes) {
		t.Errorf("receipt folder: modes %v, Elixir %v; files equal: %v", modes, g.Repo.Refine.DirModes, reflect.DeepEqual(files, wantFiles))
	}

	ref2, err := BindSource(root, slug)
	if err != nil || ref2 == nil {
		t.Fatalf("bind refined: %v, %v", ref2, err)
	}
	edit(func(s string) string { return s + "\n" })
	if _, err := RefineSource(root, slug, NewSourceRequest("again", ""), g.Repo.Refine.ContractSHA256, ref2); err != nil {
		t.Fatal(err)
	}
	// The second receipt names the first by the hash of its bytes, which carry the root.
	twice := func(text string) map[string]any {
		var m map[string]any
		if err := json.Unmarshal([]byte(text), &m); err != nil {
			t.Fatal(err)
		}
		previous, _ := m["previous_receipt"].(map[string]any)
		if previous == nil {
			t.Fatalf("no previous_receipt in %s", text)
		}
		delete(m, "previous_receipt")
		return m
	}
	got := readFile(t, path)
	if !reflect.DeepEqual(twice(got), twice(here(g.Repo.Refine.RefinedTwice))) {
		t.Fatalf("twice refined receipt\n got %s\nwant %s", got, here(g.Repo.Refine.RefinedTwice))
	}
	var named struct {
		Previous SourceRef `json:"previous_receipt"`
	}
	if err := json.Unmarshal([]byte(got), &named); err != nil || named.Previous.SHA256 != sha256Of(refinedOnce) ||
		named.Previous.Path != filepath.Join(dir, sha256Of(refinedOnce)+".json") || readFile(t, named.Previous.Path) != refinedOnce {
		t.Errorf("the second receipt names %+v, want the first receipt as its hash-named archive", named.Previous)
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 3 {
		t.Errorf("%d files after two refines, want current plus two archives", len(entries))
	}

	final, err := BindSource(root, slug)
	if err != nil || final == nil {
		t.Fatalf("bind final: %v, %v", final, err)
	}
	card, err := SourceCard(final)
	if err != nil {
		t.Fatal(err)
	}
	// The Elixir card names the receipt in its own temporary folder, and states the hash of
	// bytes that are equal to ours; everything else is the same.
	want := strings.ReplaceAll(g.Repo.Refine.Card, elixirPath, path)
	want = strings.Replace(want, "Manifest sha256: "+strings.Split(strings.Split(want, "Manifest sha256: ")[1], ";")[0], "Manifest sha256: "+final.SHA256, 1)
	want = strings.Replace(want, "contract: "+strings.Split(strings.Split(want, "contract: ")[1], ".")[0], "contract: "+final.ContractSHA256, 1)
	if card != want {
		t.Errorf("card\n got %q\nwant %q", card, want)
	}
}

func TestCaptureSourceNeedsTheIntentsComparisonAndPublishesNothingWithout(t *testing.T) {
	g := loadFactsGolden(t)
	root := provenanceFixture(t, g)
	cfg, err := LoadConfig(root)
	if err != nil {
		t.Fatal(err)
	}
	// "broken" has only intent.md; remove its comparison.
	md := filepath.Join(root, IntentMDPath("broken"))
	if err := os.WriteFile(md, []byte("# Broken\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	err = CaptureSource(root, "broken", cfg, shapeSource(g))
	if se, ok := sys.AsError(err); !ok || se.Class != "intent" || se.Reason != "lint" || se.Exit != 1 {
		t.Fatalf("got %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, ".kogen/local/provenance")); !os.IsNotExist(err) {
		t.Errorf("a failed capture created custody: %v", err)
	}
}

func TestCaptureSourceRefusesInputsElixirCouldNotEncode(t *testing.T) {
	g := loadFactsGolden(t)
	root := provenanceFixture(t, g)
	cfg, err := LoadConfig(root)
	if err != nil {
		t.Fatal(err)
	}
	bad := shapeSource(g)
	bad.Request = "a\xffb"
	if err := CaptureSource(root, g.Repo.Slug, cfg, bad); err == nil {
		t.Error("a request that is not UTF-8 was recorded")
	}
	for name, rounds := range map[string][]map[string]any{
		"no answers":           {{"questions": []any{}}},
		"answer not text":      {{"questions": []any{}, "answers": map[string]any{"1": json.Number("3")}}},
		"number not integer":   {{"questions": []any{}, "answers": map[string]any{"one": "a"}}},
		"options not a list":   {{"questions": []any{map[string]any{"options": "x"}}, "answers": map[string]any{"1": "a"}}},
		"option not an object": {{"questions": []any{map[string]any{"options": []any{"x"}}}, "answers": map[string]any{"1": "a"}}},
	} {
		st := shapeSource(g)
		st.Rounds = rounds
		if err := CaptureSource(root, g.Repo.Slug, cfg, st); err == nil {
			t.Errorf("%s: captured", name)
		}
	}
	if _, err := os.Stat(SourcePath(root, g.Repo.Slug)); !os.IsNotExist(err) {
		t.Errorf("a refused capture published a receipt: %v", err)
	}
}

func TestResolveRoundPicksLabelsOnlyForSingleLetters(t *testing.T) {
	round := map[string]any{
		"input": "kept",
		"questions": []any{
			map[string]any{"options": []any{map[string]any{"label": "Alpha"}, map[string]any{"label": "Beta"}}},
			map[string]any{"options": []any{}},
			map[string]any{"options": []any{map[string]any{"label": "Gamma"}}},
			map[string]any{},
		},
		"answers": map[string]any{
			"1": "a", "2": "b", "3": "b", "4": "a", "5": "a", "6": "ab", "7": "A", "8": "a\n", "9": "", "10": "é",
			"+1": "b\n", // picks option b of question 1 although it ends in a newline
			"0":  "a",   // like Enum.at, 0 counts from the end: the last question has no options
			"-1": "b", "-2": "a", "-3": "a", "-9": "a",
			"99999999999999999999": "a",
		},
	}
	out, err := resolveRound(round)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]any{
		"1": "Alpha", "2": "b", "3": "b", "4": "a", "5": "a", "6": "ab", "7": "A", "8": "a\n", "9": "", "10": "é",
		"+1": "Beta", "0": "a", "-1": "b", "-2": "a", "-3": "a", "-9": "a", "99999999999999999999": "a",
	}
	// Answer number n selects question n-1 counting from the end when negative: "-2" is
	// question index -3, the second question (no options); "-3" the first.
	want["-3"] = "Alpha"
	if got := out["resolved_answers"].(map[string]any); !reflect.DeepEqual(got, want) {
		t.Errorf("resolved\n got %v\nwant %v", got, want)
	}
	if out["input"] != "kept" || round["resolved_answers"] != nil {
		t.Errorf("the round is copied, not changed: %v / %v", out, round)
	}
}

func TestNewSourceRequestRecordsExactTextAndLabelsStandardInput(t *testing.T) {
	r := NewSourceRequest(publishText, "")
	if r.Text != publishText || r.SourcePath != "-" || r.SHA256 != sha256Of(publishText) {
		t.Errorf("%+v", r)
	}
	if r := NewSourceRequest("x", "dir/request.md"); r.SourcePath != "dir/request.md" {
		t.Errorf("%+v", r)
	}
}

func TestPublishSourceFirstReceiptHasNoArchiveAndNoTemporaryFile(t *testing.T) {
	root := t.TempDir()
	if err := PublishSource(root, "x", publishDoc("c", "cmp")); err != nil {
		t.Fatal(err)
	}
	entries, _ := os.ReadDir(filepath.Dir(SourcePath(root, "x")))
	if len(entries) != 1 || entries[0].Name() != "current.json" {
		t.Errorf("folder holds %v", entries)
	}
	// Publishing identical bytes again keeps one archive, intact.
	for i := 0; i < 2; i++ {
		if err := PublishSource(root, "x", publishDoc("c", "cmp")); err != nil {
			t.Fatal(err)
		}
	}
	entries, _ = os.ReadDir(filepath.Dir(SourcePath(root, "x")))
	if len(entries) != 2 {
		t.Errorf("identical republication: folder holds %v", entries)
	}
}

func TestPublishSourceTightensLooseFoldersAndReplacesStaleTemporaryFile(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Dir(SourcePath(root, "x"))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(filepath.Dir(dir), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(SourcePath(root, "x")+".tmp", []byte("left by a crash"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := PublishSource(root, "x", publishDoc("c", "cmp")); err != nil {
		t.Fatal(err)
	}
	for _, d := range []string{dir, filepath.Dir(dir)} {
		if fi, _ := os.Stat(d); fi.Mode().Perm() != 0o700 {
			t.Errorf("%s is %o", d, fi.Mode().Perm())
		}
	}
	if fi, _ := os.Stat(SourcePath(root, "x")); fi.Mode().Perm() != 0o600 {
		t.Errorf("receipt is %o", fi.Mode().Perm())
	}
	if _, err := os.Stat(SourcePath(root, "x") + ".tmp"); !os.IsNotExist(err) {
		t.Errorf("temporary file remains: %v", err)
	}
}

func TestPublishSourceRefusesUnreadableCurrentReceiptAndEncodingFailures(t *testing.T) {
	root := t.TempDir()
	p := SourcePath(root, "x")
	if err := os.MkdirAll(p, 0o700); err != nil { // current.json is a directory
		t.Fatal(err)
	}
	sourceErr(t, PublishSource(root, "x", publishDoc("c", "cmp")), p)
	if fi, _ := os.Stat(p); !fi.IsDir() {
		t.Error("the unreadable receipt was replaced")
	}
	other := t.TempDir()
	if err := PublishSource(other, "x", map[string]any{"comparison": "bad \xff"}); err == nil {
		t.Error("invalid UTF-8 was published")
	}
	if _, err := os.Stat(SourcePath(other, "x")); !os.IsNotExist(err) {
		t.Errorf("a receipt exists after a failed encoding: %v", err)
	}
}

func TestBindSourceRefusesAnythingButAnIntactVersionOneReceipt(t *testing.T) {
	good := func(root string) {
		t.Helper()
		if err := PublishSource(root, "x", publishDoc("c1", "cmp")); err != nil {
			t.Fatal(err)
		}
	}
	rewrite := func(root, content string) {
		t.Helper()
		p := SourcePath(root, "x")
		if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	cases := []struct {
		name  string
		setup func(root string)
		sha   string
	}{
		{"version 2", func(r string) { good(r); rewrite(r, `{"version":2,"contract_sha256":"c1"}`) }, "c1"},
		{"version as float", func(r string) { good(r); rewrite(r, `{"version":1.0,"contract_sha256":"c1"}`) }, "c1"},
		{"version as text", func(r string) { good(r); rewrite(r, `{"version":"1","contract_sha256":"c1"}`) }, "c1"},
		{"no version", func(r string) { good(r); rewrite(r, `{"contract_sha256":"c1"}`) }, "c1"},
		{"no contract", func(r string) { good(r); rewrite(r, `{"version":1}`) }, "c1"},
		{"contract not text", func(r string) { good(r); rewrite(r, `{"version":1,"contract_sha256":1}`) }, "c1"},
		{"not JSON", func(r string) { good(r); rewrite(r, `{"version":1,`) }, "c1"},
		{"trailing data", func(r string) { good(r); rewrite(r, `{"version":1,"contract_sha256":"c1"} x`) }, "c1"},
		{"array", func(r string) { good(r); rewrite(r, `[1]`) }, "c1"},
		{"invalid UTF-8", func(r string) { good(r); rewrite(r, "{\"version\":1,\"contract_sha256\":\"c1\",\"x\":\"\xff\"}") }, "c1"},
		{"empty file", func(r string) { good(r); rewrite(r, ``) }, "c1"},
		{"too open file", func(r string) { good(r); os.Chmod(SourcePath(r, "x"), 0o644) }, "c1"},
		{"too open folder", func(r string) { good(r); os.Chmod(filepath.Dir(SourcePath(r, "x")), 0o750) }, "c1"},
		{"receipt is a symlink", func(r string) {
			good(r)
			p := SourcePath(r, "x")
			os.Rename(p, p+".real")
			os.Symlink(p+".real", p)
		}, "c1"},
		{"receipt is a directory", func(r string) { os.MkdirAll(SourcePath(r, "x"), 0o700) }, "c1"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			root := t.TempDir()
			c.setup(root)
			ref, err := BindSource(root, "x")
			if ref != nil {
				t.Fatalf("bound %+v", ref)
			}
			sourceErr(t, err, SourcePath(root, "x"))
		})
	}
	t.Run("intact", func(t *testing.T) {
		root := t.TempDir()
		good(root)
		ref, err := BindSource(root, "x")
		if err != nil || ref == nil || ref.ContractSHA256 != "c1" {
			t.Fatalf("%+v, %v", ref, err)
		}
		// Extra members and a nested version do not matter; later versions of the file bind.
		rewrite(root, `{"version":1,"contract_sha256":"c1","extra":{"version":2}}`)
		if ref, err := BindSource(root, "x"); err != nil || ref == nil {
			t.Fatalf("%+v, %v", ref, err)
		}
	})
}

func TestValidateSourceRefusesChangedRemovedAndUnsafeCustody(t *testing.T) {
	setup := func(t *testing.T) (string, *SourceRef) {
		t.Helper()
		root := t.TempDir()
		if err := PublishSource(root, "x", publishDoc("c", "cmp")); err != nil {
			t.Fatal(err)
		}
		ref, err := BindSource(root, "x")
		if err != nil || ref == nil {
			t.Fatal(ref, err)
		}
		return root, ref
	}
	if err := ValidateSource(nil); err != nil {
		t.Errorf("a legacy (nil) reference is valid: %v", err)
	}
	t.Run("appended byte", func(t *testing.T) {
		root, ref := setup(t)
		f, _ := os.OpenFile(ref.Path, os.O_APPEND|os.O_WRONLY, 0)
		f.WriteString(" ")
		f.Close()
		sourceErr(t, ValidateSource(ref), ref.Path)
		_ = root
	})
	t.Run("removed", func(t *testing.T) {
		_, ref := setup(t)
		os.Remove(ref.Path)
		sourceErr(t, ValidateSource(ref), ref.Path)
	})
	t.Run("wrong hash", func(t *testing.T) {
		_, ref := setup(t)
		bad := *ref
		bad.SHA256 = sha256Of("other")
		sourceErr(t, ValidateSource(&bad), ref.Path)
	})
	t.Run("file mode", func(t *testing.T) {
		_, ref := setup(t)
		for _, m := range []os.FileMode{0o644, 0o640, 0o400, 0o700} {
			os.Chmod(ref.Path, m)
			sourceErr(t, ValidateSource(ref), ref.Path)
		}
		os.Chmod(ref.Path, 0o600)
		if err := ValidateSource(ref); err != nil {
			t.Error(err)
		}
	})
	t.Run("folder modes", func(t *testing.T) {
		_, ref := setup(t)
		for _, d := range []string{filepath.Dir(ref.Path), filepath.Dir(filepath.Dir(ref.Path))} {
			os.Chmod(d, 0o755)
			sourceErr(t, ValidateSource(ref), ref.Path)
			os.Chmod(d, 0o700)
		}
		if err := ValidateSource(ref); err != nil {
			t.Error(err)
		}
	})
	t.Run("symlinked ancestors", func(t *testing.T) {
		for _, up := range []int{1, 2, 3, 4} {
			root, ref := setup(t)
			d := ref.Path
			for i := 0; i < up; i++ {
				d = filepath.Dir(d)
			}
			os.Rename(d, d+"-moved")
			os.Symlink(d+"-moved", d)
			sourceErr(t, ValidateSource(ref), ref.Path)
			_ = root
		}
	})
	t.Run("file replaced by symlink", func(t *testing.T) {
		_, ref := setup(t)
		os.Rename(ref.Path, ref.Path+".real")
		os.Symlink(ref.Path+".real", ref.Path)
		sourceErr(t, ValidateSource(ref), ref.Path)
	})
	t.Run("reference without path or hash", func(t *testing.T) {
		sourceErr(t, ValidateSource(SourceRefFromMap(map[string]any{})), "")
		sourceErr(t, ValidateSource(SourceRefFromMap(map[string]any{"path": 3, "sha256": 4})), "")
	})
}

func TestSourceRefMapRoundTripAndEquality(t *testing.T) {
	ref := &SourceRef{Path: "/p/current.json", SHA256: "aa", ContractSHA256: "bb"}
	m := ref.Map()
	if !reflect.DeepEqual(m, map[string]any{"path": "/p/current.json", "sha256": "aa", "contract_sha256": "bb"}) {
		t.Errorf("%v", m)
	}
	if back := SourceRefFromMap(m); !back.Equal(ref) || back == ref {
		t.Errorf("round trip %+v", back)
	}
	archive := &SourceRef{Path: "/p/aa.json", SHA256: "aa"}
	if _, has := archive.Map()["contract_sha256"]; has {
		t.Error("an archive reference carries no contract hash")
	}
	var none *SourceRef
	if none.Map() != nil || SourceRefFromMap(nil) != nil || !none.Equal(nil) || none.Equal(ref) || ref.Equal(nil) || ref.Equal(archive) {
		t.Error("nil and inequality")
	}
	b, err := EncodeJSON(ref)
	if err != nil || string(b) != `{"contract_sha256":"bb","path":"/p/current.json","sha256":"aa"}` {
		t.Errorf("%s %v", b, err)
	}
}

func TestSourceMessageAndCard(t *testing.T) {
	root := t.TempDir()
	if err := PublishSource(root, "x", publishDoc("c", "addressed: a\nomitted: b")); err != nil {
		t.Fatal(err)
	}
	ref, err := BindSource(root, "x")
	if err != nil || ref == nil {
		t.Fatal(ref, err)
	}
	want := "Diagnostic source provenance (not authority): " + ref.Path + "\nManifest sha256: " + ref.SHA256 + "; contract: c. Retrieve full originals with read_file. Only the approved Intent authorizes implementation; omissions require ordinary Refine and new exact approval. Mapping is an aid, not proof."
	if got := SourceMessage(ref); got != want {
		t.Errorf("message\n got %q\nwant %q", got, want)
	}
	card, err := SourceCard(ref)
	if err != nil || card != want+"\nSource comparison:\naddressed: a\nomitted: b" {
		t.Errorf("card %q, %v", card, err)
	}
	if card, err := SourceCard(nil); err != nil || card != "Source provenance: unavailable (legacy)" {
		t.Errorf("legacy card %q, %v", card, err)
	}
	os.Remove(ref.Path)
	if _, err := SourceCard(ref); err == nil {
		t.Error("a card for a missing receipt")
	} else {
		sourceErr(t, err, ref.Path)
	}

	// A receipt without a text comparison cannot produce a card.
	other := t.TempDir()
	if err := PublishSource(other, "x", map[string]any{"version": json.Number("1"), "contract_sha256": "c"}); err != nil {
		t.Fatal(err)
	}
	ref, _ = BindSource(other, "x")
	if _, err := SourceCard(ref); err == nil || errors.Is(err, os.ErrNotExist) {
		t.Errorf("card without comparison: %v", err)
	}
}

func TestRefineSourceWithoutReceiptDoesNothing(t *testing.T) {
	g := loadFactsGolden(t)
	root := provenanceFixture(t, g)
	if _, err := RefineSource(root, g.Repo.Slug, NewSourceRequest("c", ""), "prior", nil); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, ".kogen/local/provenance")); !os.IsNotExist(err) {
		t.Errorf("custody created for a legacy Intent: %v", err)
	}
}

func TestRefineSourceRefusesChangedOrDeletedBoundReceipt(t *testing.T) {
	// ExUnit (project part): Refine refuses changed or deleted bound source during inference without publishing or revoking approval
	for _, drift := range []string{"changed", "deleted"} {
		t.Run(drift, func(t *testing.T) {
			g := loadFactsGolden(t)
			root := provenanceFixture(t, g)
			cfg, _ := LoadConfig(root)
			if err := CaptureSource(root, g.Repo.Slug, cfg, shapeSource(g)); err != nil {
				t.Fatal(err)
			}
			ref, err := BindSource(root, g.Repo.Slug)
			if err != nil || ref == nil {
				t.Fatal(ref, err)
			}
			if drift == "changed" {
				os.WriteFile(ref.Path, []byte(readFile(t, ref.Path)+" "), 0o600)
			} else {
				os.Remove(ref.Path)
			}
			before, readErr := os.ReadFile(ref.Path)
			entries, _ := os.ReadDir(filepath.Dir(ref.Path))
			_, err = RefineSource(root, g.Repo.Slug, NewSourceRequest("fix", ""), g.Repo.ContractSHA256, ref)
			sourceErr(t, err, ref.Path)
			after, afterErr := os.ReadFile(ref.Path)
			if string(before) != string(after) || (readErr == nil) != (afterErr == nil) {
				t.Error("a refused refine changed the receipt")
			}
			if now, _ := os.ReadDir(filepath.Dir(ref.Path)); len(now) != len(entries) {
				t.Error("a refused refine archived or created files")
			}
		})
	}
}

func TestRefineSourceKeepsEarlierCorrectionsAndRefusesNoComparison(t *testing.T) {
	g := loadFactsGolden(t)
	root := provenanceFixture(t, g)
	cfg, _ := LoadConfig(root)
	slug := g.Repo.Slug
	if err := CaptureSource(root, slug, cfg, shapeSource(g)); err != nil {
		t.Fatal(err)
	}
	ref, _ := BindSource(root, slug)
	md := filepath.Join(root, IntentMDPath(slug))
	os.WriteFile(md, []byte(strings.Replace(readFile(t, md), "\n## Source comparison\n", "\n## Renamed comparison\n", 1)), 0o644)
	before := readFile(t, ref.Path)
	_, err := RefineSource(root, slug, NewSourceRequest("c", ""), g.Repo.ContractSHA256, ref)
	if se, ok := sys.AsError(err); !ok || se.Reason != "lint" {
		t.Fatalf("got %v", err)
	}
	if readFile(t, ref.Path) != before {
		t.Error("the receipt changed although the refined Intent has no comparison")
	}
	if _, err := RefineSource(root, slug, SourceRequest{Text: "\xff"}, "p", ref); err == nil {
		t.Error("a correction that is not UTF-8 was recorded")
	}

	var doc struct {
		Corrections []SourceRequest `json:"corrections"`
		Prior       []string
	}
	os.WriteFile(md, []byte(strings.Replace(readFile(t, md), "\n## Renamed comparison\n", "\n## Source comparison\n", 1)), 0o644)
	if _, err := RefineSource(root, slug, NewSourceRequest("one", ""), "p1", ref); err != nil {
		t.Fatal(err)
	}
	next, err := BindSource(root, slug)
	if err != nil || next == nil {
		t.Fatal(next, err)
	}
	os.WriteFile(md, []byte(readFile(t, md)+"x\n"), 0o644)
	if _, err := RefineSource(root, slug, NewSourceRequest("two", "f.txt"), "p2", next); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal([]byte(readFile(t, SourcePath(root, slug))), &doc); err != nil {
		t.Fatal(err)
	}
	if len(doc.Corrections) != 2 || doc.Corrections[0].Text != "one" || doc.Corrections[1].Text != "two" || doc.Corrections[1].SourcePath != "f.txt" {
		t.Errorf("corrections %+v", doc.Corrections)
	}
	var raw struct {
		Corrections []map[string]string `json:"corrections"`
	}
	json.Unmarshal([]byte(readFile(t, SourcePath(root, slug))), &raw)
	if raw.Corrections[0]["prior_contract_sha256"] != "p1" || raw.Corrections[1]["prior_contract_sha256"] != "p2" {
		t.Errorf("prior contract hashes %+v", raw.Corrections)
	}
}

func TestExactApprovalRefusesSourceDriftDuringReadiness(t *testing.T) {
	// ExUnit (project part): exact approval refuses source drift during readiness instead of silently rebinding it.
	// Readiness runs project code that may append to the receipt. The approval's recorded
	// reference must then fail validation, and binding again yields a different reference,
	// never the recorded one.
	root := t.TempDir()
	if err := PublishSource(root, "fixture", publishDoc("sha", "cmp")); err != nil {
		t.Fatal(err)
	}
	recorded, err := BindSource(root, "fixture")
	if err != nil || recorded == nil {
		t.Fatal(recorded, err)
	}
	approval := SourceRefFromMap(recorded.Map())
	f, _ := os.OpenFile(recorded.Path, os.O_APPEND|os.O_WRONLY, 0)
	f.WriteString(" ")
	f.Close()
	sourceErr(t, ValidateSource(approval), recorded.Path)
	again, err := BindSource(root, "fixture")
	if err != nil || again == nil || again.Equal(approval) {
		t.Fatalf("rebinding after drift gave %+v, %v", again, err)
	}
}

// Ports test/integration/source_provenance_files_test.exs "historical contract refresh
// retains exact originals and predecessor custody".
func TestHistoricalContractRefreshRetainsExactOriginalsAndPredecessorCustody(t *testing.T) {
	root := t.TempDir()
	doc := map[string]any{
		"version":         json.Number("1"),
		"contract_sha256": "prior",
		"comparison":      "addressed: request",
		"request":         NewSourceRequest("exact request\r\n", "-"),
		"rounds":          []any{map[string]any{"answer": "yes"}},
		"corrections":     []any{},
		"origin":          map[string]any{"head": "original"},
	}
	if err := PublishSource(root, "example", doc); err != nil {
		t.Fatal(err)
	}
	path := SourcePath(root, "example")
	original := readFile(t, path)
	historical, err := BindSource(root, "example")
	if err != nil || historical == nil || historical.ContractSHA256 != "prior" {
		t.Fatalf("a receipt bound to an earlier contract still binds: %+v, %v", historical, err)
	}
	refreshed, err := RefreshSource(root, "example", "current", historical)
	if err != nil {
		t.Fatal(err)
	}
	if refreshed.ContractSHA256 != "current" {
		t.Errorf("refreshed contract %q", refreshed.ContractSHA256)
	}
	var current map[string]any
	if err := json.Unmarshal([]byte(readFile(t, path)), &current); err != nil {
		t.Fatal(err)
	}
	if current["prior_contract_sha256"] != "prior" {
		t.Errorf("prior contract %v", current["prior_contract_sha256"])
	}
	previous, _ := current["previous_receipt"].(map[string]any)
	if previous["sha256"] != sha256Of(original) || readFile(t, previous["path"].(string)) != original {
		t.Errorf("previous_receipt %v does not hold the original receipt", previous)
	}
	var first map[string]any
	if err := json.Unmarshal([]byte(original), &first); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"request", "rounds", "corrections", "origin"} {
		if !reflect.DeepEqual(current[key], first[key]) {
			t.Errorf("%s changed: %v, was %v", key, current[key], first[key])
		}
	}

	again, err := RefreshSource(root, "example", "current", refreshed)
	if err != nil || !again.Equal(refreshed) {
		t.Errorf("refreshing to the contract it binds: %+v, %v", again, err)
	}
	if err := RestoreSource(refreshed, []byte(original)); err != nil {
		t.Fatal(err)
	}
	if readFile(t, path) != original {
		t.Error("restore did not put the original receipt back")
	}
	refreshed, err = RefreshSource(root, "example", "current", historical)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("external edit"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := RestoreSource(refreshed, []byte(original)); err != nil {
		t.Fatal(err)
	}
	if got := readFile(t, path); got != "external edit" {
		t.Errorf("restore overwrote an external edit: %q", got)
	}
}

func TestRefreshSourceRefusesAReceiptThatIsNotTheOneRead(t *testing.T) {
	root := t.TempDir()
	if err := PublishSource(root, "x", publishDoc("c1", "cmp")); err != nil {
		t.Fatal(err)
	}
	read, err := BindSource(root, "x")
	if err != nil {
		t.Fatal(err)
	}
	if err := PublishSource(root, "x", publishDoc("c1", "another comparison")); err != nil {
		t.Fatal(err)
	}
	if _, err := RefreshSource(root, "x", "c2", read); err == nil {
		t.Fatal("a receipt replaced since it was read was refreshed")
	} else {
		sourceErr(t, err, SourcePath(root, "x"))
	}
	if got, err := RefreshSource(root, "legacy", "c2", nil); got != nil || err != nil {
		t.Errorf("a legacy Intent refreshes to nothing: %+v, %v", got, err)
	}
}

func TestBindSourceRefusesAProvenanceFolderWithoutAReceipt(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Dir(SourcePath(root, "x")), 0o700); err != nil {
		t.Fatal(err)
	}
	ref, err := BindSource(root, "x")
	if ref != nil {
		t.Fatalf("bound %+v", ref)
	}
	sourceErr(t, err, SourcePath(root, "x"))
}

func TestResolveApprovalPinsAStaleMarkersReceiptByItsDigest(t *testing.T) {
	root := gitRepo(t)
	slug := "pin"
	writeFile(t, root, ".kogen/project.yaml", "version: 1\ncommands:\n  acceptance:\n    run: x\n    steps_dir: s\n")
	writeFile(t, root, IntentMDPath(slug), "# Pin\n")
	cfg, err := LoadConfig(root)
	if err != nil {
		t.Fatal(err)
	}
	paths, err := Baseline(root, slug, cfg)
	if err != nil {
		t.Fatal(err)
	}
	sha := Hash(root, paths)
	if err := PublishSource(root, slug, publishDoc(sha, "cmp")); err != nil {
		t.Fatal(err)
	}
	bound, err := BindSource(root, slug)
	if err != nil {
		t.Fatal(err)
	}
	approval := &Approval{Slug: slug, SHA256: sha, SourceProvenance: bound.Map()}
	if got, err := ResolveApproval(root, slug, approval); err != nil || !got.Equal(bound) {
		t.Fatalf("a current marker resolves to its receipt: %+v, %v", got, err)
	}
	if got, err := ResolveApproval(root, slug, nil); got != nil || err != nil {
		t.Errorf("no marker: %+v, %v", got, err)
	}
	if got, err := ResolveApproval(root, slug, &Approval{Slug: slug, SHA256: sha}); got != nil || err != nil {
		t.Errorf("a legacy marker: %+v, %v", got, err)
	}

	// A stale marker (another contract) whose receipt was displaced resolves to the archive.
	if err := PublishSource(root, slug, publishDoc("other", "newer")); err != nil {
		t.Fatal(err)
	}
	stale := &Approval{Slug: slug, SHA256: "stale", SourceProvenance: bound.Map()}
	got, err := ResolveApproval(root, slug, stale)
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(filepath.Dir(bound.Path), bound.SHA256+".json"); got.Path != want {
		t.Errorf("resolved %s, want the archive %s", got.Path, want)
	}

	// The pointer must name the current path and a digest.
	bad := bound.Map()
	bad["path"] = filepath.Join(root, "elsewhere.json")
	sourceErr(t, errOf(ResolveApproval(root, slug, &Approval{Slug: slug, SHA256: "stale", SourceProvenance: bad})), SourcePath(root, slug))
	bad = bound.Map()
	bad["sha256"] = "not-a-digest"
	sourceErr(t, errOf(ResolveApproval(root, slug, &Approval{Slug: slug, SHA256: "stale", SourceProvenance: bad})), SourcePath(root, slug))
	// A marker that still authorizes the contract must find its receipt exactly as pinned.
	current := &Approval{Slug: slug, SHA256: sha, SourceProvenance: bound.Map()}
	sourceErr(t, errOf(ResolveApproval(root, slug, current)), "expected SHA-256 "+bound.SHA256)
}

func errOf(_ *SourceRef, err error) error { return err }

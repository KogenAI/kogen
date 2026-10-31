package build

import (
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"kogen/project"
)

// k-revod-gate: an on_demand review must read every pinned part covering a changed hunk (by
// the manifest's per-part covered line ranges) before any verdict, and a blocking finding that
// asserts no product defect is invalid feedback, never review_blocked.

// The S-LEVERS Build 2c768016 blocker (28 Oct 2026, on_demand, parts=181, parts_read=2).
const revodGateHistoricalBlocker = "The required inspection of the complete pinned candidate source was not completed... no product defect is asserted by this finding."

const (
	// revodGateLines records of revodGateRecord make a candidate whose review source is 181
	// pinned parts; one record in the middle changes.
	revodGateLines   = 31_835
	revodGateChanged = 15_000
)

func revodGateRecord(i int) string { return fmt.Sprintf("record %06d of the long fixture\n", i) }

// revodGateContent is the long file, with record changed replaced when changed > 0.
func revodGateContent(changed int) string {
	var b strings.Builder
	for i := 1; i <= revodGateLines; i++ {
		if i == changed {
			b.WriteString("record CHANGED of the long fixture\n")
			continue
		}
		b.WriteString(revodGateRecord(i))
	}
	return b.String()
}

// revodGateLong is an on_demand project whose start HEAD already holds the long file; the
// builder changes one record of it, so only the diff part and the one file-text part holding
// that hunk cover changed lines.
func revodGateLong(t *testing.T) (*env, string) {
	t.Helper()
	e := newEnv(t)
	e.write(".kogen/project.yaml", e.read(".kogen/project.yaml")+"review_material:\n  mode: on_demand\n")
	e.write("app.txt", revodGateContent(0))
	// The Intent is committed too, so that app.txt is the candidate's only change.
	e.run("git", "add", ".kogen/project.yaml", "app.txt", ".kogen/intents", stepsFile)
	e.run("git", "commit", "-qm", "long fixture, on_demand review")
	e.approve()
	candidate := revodGateContent(revodGateChanged)
	e.prov.then(e.prov.calls("write_file", map[string]any{"path": "app.txt", "content": candidate}, "finish", map[string]any{"summary": "done"}))
	return e, candidate
}

// revodGateExpected is, independently of required_parts, the parts whose covers hold a line of
// the app.txt diff block after its four header lines (the hunk) or the candidate lines of the
// hunk (the changed record and its three context records on each side).
func revodGateExpected(catalog map[string]any) []int {
	var want []int
	for i, p := range catalog["parts"].([]any) {
		hit := false
		for _, c := range p.(map[string]any)["covers"].([]any) {
			cv := c.(map[string]any)
			first, last := int(cv["first_line"].(float64)), int(cv["last_line"].(float64))
			switch {
			case cv["path"] != "app.txt":
			case cv["kind"] == "diff" && last >= 5:
				hit = true
			case cv["kind"] == "file" && first <= revodGateChanged+3 && revodGateChanged-3 <= last:
				hit = true
			}
		}
		if hit {
			want = append(want, i+1)
		}
	}
	return want
}

func catalogRequired(catalog map[string]any) []int {
	var out []int
	list, _ := catalog["required_parts"].([]any)
	for _, n := range list {
		out = append(out, int(n.(float64)))
	}
	return out
}

// latestCatalog is the pinned source catalog of the newest review request.
func latestCatalog(f *fakeProvider) map[string]any {
	reqs := f.reviewRequests()
	return reviewCatalog(f.t, reqs[len(reqs)-1])
}

// readPartsOf reads the given parts (numbers) of the newest review request's catalog.
func readPartsOf(f *fakeProvider, numbers func(catalog map[string]any) []int) handler {
	return func(w http.ResponseWriter, r *http.Request) {
		catalog := latestCatalog(f)
		paths := catalogParts(catalog)
		var pairs []any
		for _, n := range numbers(catalog) {
			pairs = append(pairs, "read_file", map[string]any{"path": paths[n-1]})
		}
		f.calls(pairs...)(w, r)
	}
}

func fixed(n ...int) func(map[string]any) []int { return func(map[string]any) []int { return n } }

func intsOf(v any) []int {
	out := []int{}
	list, _ := v.([]any)
	for _, n := range list {
		out = append(out, int(n.(float64)))
	}
	return out
}

func TestKRevodGateHunkCoverage(t *testing.T) {
	t.Parallel()
	cover := func(path, kind string, first, last int) map[string]any {
		return map[string]any{"path": path, "kind": kind, "first_line": first, "last_line": last}
	}
	t.Run("ranges", func(t *testing.T) {
		t.Parallel()
		hunks := []materialHunkRange{
			{"a.go", "diff", 5, 14}, {"a.go", "file", 40, 46}, // a hunk split over parts 2 and 3
			{"a.go", "diff", 15, 19},           // a deletion-only hunk: diff lines, no candidate lines
			{"new.txt", "file", 1, 30},         // an added file's synthesized hunk
			{"gone.txt", "diff", 5, 9},         // a deleted path's hunk
			{"b.go", "file", 100, 100},         // a boundary line shared by two parts
			{"other.go", "file", 1, 3},         // no part covers this path
			{"c.go", "diff", 1_000, 1_000_000}, // no part covers these lines
		}
		covers := [][]map[string]any{
			{cover("a.go", "diff", 1, 4)},                                    // 1: diff header only
			{cover("a.go", "diff", 5, 10)},                                   // 2: hunk start
			{cover("a.go", "diff", 10, 14), cover("a.go", "file", 1, 9)},     // 3: hunk end
			{cover("a.go", "file", 10, 39)},                                  // 4: unchanged lines
			{cover("a.go", "file", 39, 40)},                                  // 5: first candidate line
			{cover("a.go", "diff", 15, 15), cover("gone.txt", "diff", 1, 4)}, // 6: deletion-only hunk
			{cover("gone.txt", "diff", 4, 9)},                                // 7: deleted path's hunk
			{cover("new.txt", "file", 1, 10)},                                // 8: added file
			{cover("new.txt", "file", 10, 30)},                               // 9: added file
			{cover("b.go", "file", 50, 100)},                                 // 10: boundary
			{cover("b.go", "file", 100, 140)},                                // 11: boundary
			{cover("b.go", "file", 101, 200)},                                // 12: after the hunk
			{cover("a.go", "file", 47, 90), cover("b.go", "diff", 100, 100)}, // 13: wrong side and lines
			{},                              // 14: covers nothing
			{cover("c.go", "diff", 1, 999)}, // 15: before the hunk
		}
		eq(t, "required", materialRequired(hunks, covers), []int{2, 3, 5, 6, 7, 8, 9, 10, 11})
		eq(t, "no hunks", materialRequired(nil, covers), []int{})
		eq(t, "no parts", materialRequired(hunks, nil), []int{})
	})
	t.Run("manifest", func(t *testing.T) {
		t.Parallel()
		// Hunks from the real diff: a split modification, a deletion-only hunk, an added file,
		// a deleted path and a binary file, located by the covers of small parts.
		b, e, _ := materialAttempt(t)
		var base, cand strings.Builder
		for i := 1; i <= 120; i++ {
			fmt.Fprintf(&base, "line %03d\n", i)
			switch {
			case i == 20:
				cand.WriteString("line 020 modified\n")
			case i >= 80 && i <= 84:
			default:
				fmt.Fprintf(&cand, "line %03d\n", i)
			}
		}
		e.write("app.txt", base.String())
		e.write("gone.txt", "gone one\ngone two\n")
		e.write("pic.bin", "\x00\x01")
		e.run("git", "add", "app.txt", "gone.txt", "pic.bin")
		e.run("git", "commit", "-qm", "base")
		b.Start = e.head()
		e.write("app.txt", cand.String())
		e.write("pic.bin", "\x00\x02")
		e.write("new.txt", "n1\nn2\nn3\n")
		if err := os.Remove(filepath.Join(e.root, "gone.txt")); err != nil {
			t.Fatal(err)
		}
		tree, err := b.repo.Tree(b.Start, nil)
		if err != nil {
			t.Fatal(err)
		}
		diffOf := func(p string) string {
			d, err := b.repo.Diff(b.Start, tree, []string{p})
			if err != nil {
				t.Fatal(err)
			}
			return d
		}
		appDiff, goneDiff, binDiff := diffOf("app.txt"), diffOf("gone.txt"), diffOf("pic.bin")
		source := "# Check results\n\n# Diff of existing/deleted paths against start HEAD\n\n" + appDiff + goneDiff + binDiff +
			"\n# Full text of every changed or added file\n\n--- app.txt\n" + cand.String() + "\n--- gone.txt (deleted)\n--- new.txt (added; mode 100644)\nn1\nn2\nn3\n\n--- pic.bin (binary)\n"
		catalog := []map[string]any{
			{"path": "app.txt", "status": "changed", "mode": "100644"},
			{"path": "gone.txt", "status": "deleted", "mode": "100644"},
			{"path": "new.txt", "status": "added", "mode": "100644"},
			{"path": "pic.bin", "status": "changed", "mode": "100644"},
		}
		texts := []materialFileText{{"app.txt", "--- app.txt\n", cand.String()}, {"new.txt", "--- new.txt (added; mode 100644)\n", "n1\nn2\nn3\n"}}
		manifest, segments, ranges, err := b.materialManifest(tree, catalog, texts, source)
		if err != nil {
			t.Fatal(err)
		}
		if len(manifest[0]["hunks"].([]map[string]any)) != 2 || len(manifest[1]["hunks"].([]map[string]any)) != 0 || len(manifest[3]["hunks"].([]map[string]any)) != 0 {
			t.Fatalf("manifest %v", manifest)
		}
		m := materialSet{Source: source, Segments: segments}
		// The changed bytes, found independently in source: each hunk's diff text (header to
		// the end of its body) and the candidate lines of each hunk with new lines.
		var spans [][2]int
		for _, block := range []string{appDiff, goneDiff} {
			at := strings.Index(source, block)
			for _, h := range strings.SplitAfter(block, "\n@@")[1:] {
				start := at + strings.Index(block, h) - 2
				spans = append(spans, [2]int{start, start + 2 + len(h)})
			}
		}
		text := strings.Index(source, "--- app.txt\n") + len("--- app.txt\n")
		lineAt := func(n int) int { return text + strings.Index(cand.String(), fmt.Sprintf("line %03d", n)) }
		// The candidate lines of the two hunks: 17-23 around the modification, and the context
		// 77-79 and 85-87 that the deletion of 80-84 leaves as its new lines.
		spans = append(spans, [2]int{lineAt(17), lineAt(24)}, [2]int{lineAt(77), lineAt(88)})
		added := strings.Index(source, "n1\nn2\nn3\n")
		spans = append(spans, [2]int{added, added + len("n1\nn2\nn3\n")})
		for _, size := range []int{40, 97, 256, len(source)} {
			var covers [][]map[string]any
			want := []int{}
			for from, i := 0, 1; from < len(source); from, i = from+size, i+1 {
				to := min(from+size, len(source))
				covers = append(covers, materialCovers(m, from, to))
				if slices.ContainsFunc(spans, func(s [2]int) bool { return from < s[1] && s[0] < to }) {
					want = append(want, i)
				}
			}
			eq(t, fmt.Sprintf("required with %d-byte parts", size), materialRequired(ranges, covers), want)
		}
		for _, r := range ranges {
			if r.Path == "pic.bin" {
				t.Errorf("binary range %v", r)
			}
		}
	})
}

func TestKRevodGateHunkApproval(t *testing.T) {
	t.Parallel()
	e, candidate := revodGateLong(t)
	f := e.prov
	// The reviewer reads exactly the required parts, works through a working-window reset and
	// approves, never reading the other 179.
	f.then(readPartsOf(f, catalogRequired))
	for i := 0; i < 3; i++ {
		f.then(f.calls("write_file", map[string]any{"path": ".kogen/local/padding", "content": strings.Repeat("x", 190_000)}))
	}
	f.then(submit(f, "approve"))
	start := e.head()
	a := e.reviewed()
	if a.exit != 0 || e.head() == start {
		t.Fatalf("not landed: %d %s %s", a.exit, a.shown(), a.errs)
	}
	eq(t, "landed", e.gitOut("show", "HEAD:app.txt")+"\n", candidate)
	eq(t, "landed parent", e.gitOut("rev-parse", "HEAD^"), start)

	reqs := f.reviewRequests()
	catalog := reviewCatalog(t, reqs[0])
	parts := catalog["parts"].([]any)
	eq(t, "parts", len(parts), 181)
	want := revodGateExpected(catalog)
	if len(want) != 2 || want[0] != 1 {
		t.Fatalf("the fixture's hunk lies in parts %v, want the diff part and one file part", want)
	}
	eq(t, "required_parts", catalogRequired(catalog), want)
	opening := requestText(reqs[0])
	lacks(t, "opening", opening, "record 015000 of the long fixture")
	contains(t, "opening", opening, "Read every required\\npart completely with read_file before any verdict")
	lacks(t, "opening", opening, "no part is required before a verdict")
	instructions := requestInstructions(reqs[0])
	contains(t, "instructions", instructions, reviewerOnDemandRule)
	lacks(t, "instructions", instructions, reviewerPartsRule)

	// The reads were real complete deliveries, and they stay counted across the reset.
	paths := catalogParts(catalog)
	outputs := strings.Join(f.toolOutputs(), "\n")
	for _, n := range want {
		data, err := os.ReadFile(paths[n-1])
		if err != nil {
			t.Fatal(err)
		}
		contains(t, "read output", outputs, "1\t"+strings.TrimRight(string(data), "\n"))
	}
	var reset map[string]any
	for _, req := range reqs {
		if len(prefilledParts(t, req)) != 0 {
			t.Fatal("on_demand request carries native part data")
		}
		if h := resetHandoff(t, req); h != nil {
			reset = h
		}
	}
	if reset == nil {
		t.Fatal("no working-window reset reached the reviewer")
	}
	source := reset["review_delivery"].(map[string]any)["source"].(map[string]any)
	eq(t, "reset required", intsOf(source["required_parts"]), want)
	eq(t, "reset required unread", intsOf(source["required_unread"]), []int{})
	eq(t, "reset delivered", source["delivered"], any(float64(2)))
	note := reset["review_delivery"].(map[string]any)["note"].(string)
	contains(t, "reset note", note, "Read every part in required_parts (the parts covering changed hunks) completely before any verdict")
	lacks(t, "reset note", note, "no part is required before a verdict")

	events := e.events(e.onlyRun())
	evidence := eventsNamed(events, "review_source_evidence")
	if len(evidence) != 1 || !slices.Equal(intsOf(evidence[0]["required_parts"]), want) || evidence[0]["review"] != float64(1) {
		t.Fatalf("source evidence %v", evidence)
	}
	material := eventsNamed(events, "review_material")
	if len(material) != 1 {
		t.Fatalf("review_material %v", material)
	}
	m := material[0]
	eq(t, "mode", m["mode"], any("on_demand"))
	eq(t, "parts", m["parts"], any(float64(181)))
	eq(t, "parts_read", m["parts_read"], any(float64(2)))
	eq(t, "event required", intsOf(m["required_parts"]), want)
	eq(t, "event read", intsOf(m["read_parts"]), want)
	eq(t, "verdict", e.jsonFile(e.runPath(e.onlyRun(), "review-1.json"))["verdict"], any("approve"))
}

func TestKRevodGateMissingRead(t *testing.T) {
	t.Parallel()
	unrelated := 90
	for _, tc := range []struct {
		name   string
		first  []int
		submit func(f *fakeProvider) handler
	}{
		// An approval after reading the diff part and an unrelated part, not the file part.
		{"approve", []int{1, unrelated}, func(f *fakeProvider) handler { return submit(f, "approve") }},
		// A concrete changes verdict before reading anything.
		{"changes", nil, func(f *fakeProvider) handler {
			return submit(f, "changes", finding("blocking", "record 15000 lost its number, so the record index no longer matches"))
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			e, candidate := revodGateLong(t)
			f := e.prov
			if tc.first != nil {
				f.then(readPartsOf(f, fixed(tc.first...)))
			}
			f.then(tc.submit(f))
			f.then(readPartsOf(f, catalogRequired))
			f.then(submit(f, "approve"))
			start := e.head()
			a := e.reviewed()
			if a.exit != 0 || e.head() == start {
				t.Fatalf("not landed: %d %s %s", a.exit, a.shown(), a.errs)
			}
			eq(t, "landed", e.gitOut("show", "HEAD:app.txt")+"\n", candidate)
			lacks(t, "stdout", a.out.String(), "review_blocked")
			reqs := f.reviewRequests()
			catalog := reviewCatalog(t, reqs[0])
			required := catalogRequired(catalog)
			if len(required) != 2 || slices.Contains(required, unrelated) {
				t.Fatalf("required %v", required)
			}
			paths := catalogParts(catalog)
			// The premature verdict was sent back as invalid feedback naming the unread parts.
			feedback := f.toolOutputs()
			var invalid string
			for _, out := range feedback {
				if strings.HasPrefix(out, "invalid verdict:") {
					invalid = out
				}
			}
			unread := required
			if tc.first != nil {
				unread = []int{required[1]}
			}
			contains(t, "feedback", invalid, fmt.Sprintf("%d required hunk-covering pinned part(s) unread; read them completely before a verdict; incomplete reading is not a candidate defect; use read_file on ", len(unread)))
			for _, n := range required {
				if slices.Contains(unread, n) {
					contains(t, "feedback", invalid, paths[n-1])
				} else {
					lacks(t, "feedback", invalid, paths[n-1])
				}
			}
			events := e.events(e.onlyRun())
			if verdicts := eventsNamed(events, "review"); len(verdicts) != 1 || verdicts[0]["verdict"] != "approve" {
				t.Fatalf("review events %v", verdicts)
			}
			allowances := eventsNamed(events, "review_allowance")
			if len(allowances) != 1 || allowances[0]["why"] != "rejected_verdict" {
				t.Fatalf("allowances %v", allowances)
			}
			material := eventsNamed(events, "review_material")
			if len(material) != 1 {
				t.Fatalf("review_material %v", material)
			}
			read := slices.Clone(required)
			if tc.first != nil {
				read = []int{1, unrelated, required[1]}
				slices.Sort(read)
			}
			eq(t, "read parts", intsOf(material[0]["read_parts"]), read)
			eq(t, "parts read", material[0]["parts_read"], any(float64(len(read))))
			eq(t, "required parts", intsOf(material[0]["required_parts"]), required)
		})
	}
}

func TestKRevodGateInvalidBlocker(t *testing.T) {
	t.Parallel()
	t.Run("historical blocker ends review_invalid", func(t *testing.T) {
		t.Parallel()
		e, _ := revodGateLong(t)
		f := e.prov
		blocker := map[string]any{"path": "app.txt", "line": 1, "severity": "blocking", "message": revodGateHistoricalBlocker}
		// Each review reads its required parts, then submits the blocker until the rejected
		// verdict allowance is spent; the one automatic fresh review does the same.
		for review := 0; review < 2; review++ {
			f.then(readPartsOf(f, catalogRequired), submit(f, "changes", blocker), submit(f, "changes", blocker))
		}
		start := e.head()
		a := e.reviewed()
		eq(t, "exit", a.exit, 1)
		eq(t, "head", e.head(), start)
		run := e.onlyRun()
		eq(t, "outcome", e.result(run)["outcome"], any("review_invalid"))
		lacks(t, "stdout", a.shown(), "review_blocked")
		eq(t, "review requests", len(f.reviewRequests()), 6)
		events := e.events(run)
		var invalid int
		for _, ev := range eventsNamed(events, "review") {
			switch ev["verdict"] {
			case "invalid":
				invalid++
				eq(t, "reason", ev["reason"], any("rejected_verdict_exhausted"))
				contains(t, "problems", fmt.Sprint(ev["problems"]), "asserts no product defect")
			default:
				t.Fatalf("a verdict was accepted: %v", ev)
			}
		}
		eq(t, "invalid reviews", invalid, 2)
		if retries := eventsNamed(events, "review_retry"); len(retries) != 1 || retries[0]["kind"] != "automatic" {
			t.Fatalf("retries %v", retries)
		}
		// Both reviews actually read their two hunk-covering parts of 181.
		for _, ev := range eventsNamed(events, "review_source_evidence") {
			if ev["parts"] != float64(181) || len(intsOf(ev["required_parts"])) != 2 {
				t.Fatalf("source evidence %v", ev)
			}
		}
		feedback := strings.Join(f.toolOutputs(), "\n")
		contains(t, "feedback", feedback, "invalid verdict:\na blocking finding that asserts no product defect (such as inspection not completed) is not a verdict on the candidate")
		lacks(t, "feedback", feedback, "required hunk-covering pinned part(s) unread")
	})
	t.Run("concrete defect mentioning inspection stays a blocker", func(t *testing.T) {
		t.Parallel()
		e, _ := revodGateLong(t)
		f := e.prov
		defect := finding("blocking", "Inspection of the changed hunk shows record 15000 lost its number: the record index no longer matches the file, a product defect.")
		f.then(readPartsOf(f, catalogRequired), submit(f, "changes", defect))
		start := e.head()
		a := e.reviewed()
		eq(t, "exit", a.exit, 1)
		eq(t, "head", e.head(), start)
		contains(t, "stdout", a.out.String(), "review_blocked")
		eq(t, "outcome", e.result(e.onlyRun())["outcome"], any("review_blocked"))
		if verdicts := eventsNamed(e.events(e.onlyRun()), "review"); len(verdicts) != 1 || verdicts[0]["verdict"] != "changes" {
			t.Fatalf("review events %v", verdicts)
		}
	})
	t.Run("validation", func(t *testing.T) {
		t.Parallel()
		root := t.TempDir()
		if err := os.WriteFile(filepath.Join(root, "app.txt"), []byte("candidate"), 0o600); err != nil {
			t.Fatal(err)
		}
		// The rule holds in the default parts mode as well.
		r := &reviewRun{b: &Attempt{Root: root}}
		r.b.Baseline = []string{"fixture.feature"}
		if err := os.WriteFile(filepath.Join(root, "fixture.feature"), []byte("Feature: x\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		// The documented protected-fixture stop remains a blocker even when it clears the product.
		fixtureStop := map[string]any{"verdict": "changes", "findings": []any{map[string]any{"path": "fixture.feature", "line": int64(1), "severity": "blocking",
			"message": "The protected fixture asserts raw escaped HTML; this is a fixture defect, not a product defect."}}}
		if verdict, problems, err := r.validate(fixtureStop, nil); err != nil || verdict == nil {
			t.Fatalf("protected fixture stop refused: %v %v", problems, err)
		}
		for _, tc := range []struct {
			message string
			invalid bool
		}{
			{revodGateHistoricalBlocker, true},
			{"Inspection incomplete; this is not a product defect.", true},
			{"The review could not finish reading; it does not assert any defect.", true},
			{"Reading stopped early, without asserting a candidate defect.", true},
			{"No defect was found, but the inspection is not complete.", true},
			{"Inspection of app.txt shows the parser drops the last record: a product defect.", false},
			{"The inspection command in check.sh no longer runs, so the defect detection is disabled.", false},
			{"Defect: no product validation of empty input; inspect app.txt line 1.", false},
		} {
			args := map[string]any{"verdict": "changes", "findings": []any{map[string]any{"path": "app.txt", "line": int64(1), "severity": "blocking", "message": tc.message}}}
			verdict, problems, err := r.validate(args, nil)
			if err != nil {
				t.Fatal(err)
			}
			if got := verdict == nil; got != tc.invalid {
				t.Errorf("%q: invalid %v (%v), want %v", tc.message, got, problems, tc.invalid)
			}
			// A note may say anything.
			args["findings"] = []any{map[string]any{"path": "app.txt", "line": int64(1), "severity": "note", "message": tc.message}}
			args["verdict"] = "approve"
			if verdict, problems, _ := r.validate(args, nil); verdict == nil {
				t.Errorf("note %q refused: %v", tc.message, problems)
			}
		}
	})
}

// revodGateEmptySourceControls are 60 clean control cells whose source fits inline (no pinned
// source): the required set is empty, an approval with no reads is a valid verdict in either
// mode, and no source custody exists. One real on_demand Build of such a candidate lands
// without any read.
func revodGateEmptySourceControls(t *testing.T) {
	b, _, tree := materialAttempt(t)
	for cell := 0; cell < 60; cell++ {
		mode := []string{"on_demand", "parts"}[cell%2]
		b.Config = &project.Config{ReviewMaterial: project.ReviewMaterial{Mode: mode}}
		b.Review, b.WorkingContext = cell+1, map[string]*OwnerContext{}
		source := fmt.Sprintf("# Check results of the final pass\n\nacceptance: passed (%d scenarios)\n\n", cell%7) +
			strings.Repeat(fmt.Sprintf("--- cell%02d.txt\nclean control %d\n", cell, cell), 1+cell*37)
		input, err := b.materialPrepare(tree, testMaterial(source), materialRole(), reviewerPrompt(mode == "on_demand"), nil, nil, false)
		if err != nil {
			t.Fatal(err)
		}
		if b.WorkingContext["review"].InlineMaterial == nil || len(b.WorkingContext["review"].History) != 0 {
			t.Fatalf("cell %d pinned its source", cell)
		}
		if unread, err := b.materialRequiredUnread(input); err != nil || len(unread) != 0 {
			t.Fatalf("cell %d required %v %v", cell, unread, err)
		}
		r := &reviewRun{b: b}
		if verdict, problems, err := r.validate(map[string]any{"verdict": "approve", "findings": []any{}}, input); err != nil || verdict == nil {
			t.Fatalf("cell %d approval refused: %v %v", cell, problems, err)
		}
	}
	if _, err := os.Stat(filepath.Join(b.Run.Dir, "review-source")); !os.IsNotExist(err) {
		t.Fatal("a control cell created source custody")
	}

	e := newEnv(t)
	e.write(".kogen/project.yaml", e.read(".kogen/project.yaml")+"review_material:\n  mode: on_demand\n")
	e.run("git", "add", ".kogen/project.yaml")
	e.run("git", "commit", "-qm", "review material mode")
	e.approve()
	f := e.prov
	f.then(f.calls("write_file", map[string]any{"path": "app.txt", "content": "small clean change\n"}, "finish", map[string]any{"summary": "done"}))
	f.then(submit(f, "approve"))
	start := e.head()
	if a := e.reviewed(); a.exit != 0 || e.head() == start {
		t.Fatalf("control not landed: %d %s", a.exit, a.shown())
	}
	events := e.events(e.onlyRun())
	if len(eventsNamed(events, "review_source_evidence")) != 0 || len(eventsNamed(events, "review_material")) != 0 {
		t.Fatal("the inline control pinned source")
	}
	eq(t, "review requests", len(f.reviewRequests()), 1)
}

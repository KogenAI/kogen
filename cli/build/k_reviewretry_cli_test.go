package build

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
	"time"

	"kogen/project"
)

// The review-only resume is exercised through the real program: this builds kogen into an
// installation layout of a temporary prefix and runs `kogen intent build` and `kogen intent
// resume <build-id>` as processes against a temporary checkout and the scripted provider. Only
// processes the test starts exist, each waited for under its own deadline.

func buildKogen(t *testing.T) string {
	t.Helper()
	root := filepath.Join(t.TempDir(), "lib", "kogen")
	bin := filepath.Join(root, "bin", "kogen")
	if err := os.MkdirAll(filepath.Dir(bin), 0o755); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("go", "build", "-o", bin, ".")
	cmd.Dir = ".."
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("go build: %v\n%s", err, out)
	}
	writeFile(t, filepath.Join(root, "lib", "VERSION"), "kogen dev+12345678 (test)\n", 0o644)
	return bin
}

// cli runs one kogen command in the checkout and returns its exit code and stdout.
func (e *env) cli(bin string, args ...string) (int, string) {
	e.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, append(args, "--project", e.root)...)
	cmd.Dir = e.root
	cmd.Env = isolatedEnv("HOME="+e.home, "KOGEN_PROVIDER_URL="+e.prov.srv.URL, "KOGEN_AUTH_URL="+e.prov.srv.URL)
	var out, errs bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errs
	err := cmd.Run()
	code := 0
	if ee, ok := err.(*exec.ExitError); ok {
		code = ee.ExitCode()
	} else if err != nil {
		e.t.Fatalf("kogen %v: %v\n%s", args, err, errs.String())
	}
	return code, out.String()
}

var buildIDOf = regexp.MustCompile(`\(Build ([0-9a-f]{8})\)`)

// stopAfterTwoInvalidReviews runs `kogen intent build` until review 1 and its one fresh
// replacement have both ended without a verdict, and returns the stopped Build's id.
func (e *env) stopAfterTwoInvalidReviews(bin string) string {
	e.t.Helper()
	e.credentials()
	f := e.prov
	f.then(landScript(f)...)
	f.then(f.calls("read_file", map[string]any{"path": "app.txt"}, "list_files", map[string]any{"path": "."}, "search_text", map[string]any{"query": "candidate"}),
		prose("All good."), prose("Still good."), // review 1: read-only tools, then two prose-only turns
		submit(f, "approve", finding("blocking", "An approve verdict cannot contain a blocking finding.")),
		submit(f, "approve", finding("blocking", "An approve verdict cannot contain a blocking finding."))) // review 2
	start := e.head()
	code, out := e.cli(bin, "intent", "build", testSlug)
	if code != 1 || !strings.Contains(out, "candidate/review_invalid: the reviewer did not return a valid verdict; edits are left in place") {
		e.t.Fatalf("build exit %d\n%s", code, out)
	}
	if e.head() != start {
		e.t.Fatal("a commit was created")
	}
	m := buildIDOf.FindStringSubmatch(out)
	if m == nil {
		e.t.Fatalf("no Build id in\n%s", out)
	}
	eq(e.t, "review requests", len(f.reviewRequests()), 5)
	return m[1]
}

// checkoutSnapshot is everything a refused resume must leave exactly as it found it.
type checkoutSnapshot struct {
	files    map[string]string
	index    string
	head     string
	approval string
	runs     string
}

func (e *env) snapshot() checkoutSnapshot {
	e.t.Helper()
	c := checkoutSnapshot{files: map[string]string{}, head: e.head()}
	err := filepath.WalkDir(e.root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(e.root, path)
		if d.IsDir() {
			if rel == ".git" {
				return fs.SkipDir
			}
			return nil
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		sum := sha256.Sum256(b)
		c.files[rel] = hex.EncodeToString(sum[:])
		return nil
	})
	if err != nil {
		e.t.Fatal(err)
	}
	idx, err := os.ReadFile(filepath.Join(e.root, ".git", "index"))
	if err != nil {
		e.t.Fatal(err)
	}
	sum := sha256.Sum256(idx)
	c.index = hex.EncodeToString(sum[:])
	rel, err := filepath.Rel(e.root, project.ApprovalPath(e.root, testSlug))
	if err != nil {
		e.t.Fatal(err)
	}
	c.approval = c.files[rel]
	ids := e.runIDs()
	sort.Strings(ids)
	c.runs = strings.Join(ids, ",")
	return c
}

// TestKReviewRetryReviewOnlyResume: after both automatic conversations fail, the stop keeps
// the green tree and a durable review-only checkpoint; the real `kogen intent resume` starts
// one fresh review of that unchanged checkout, with no builder round and no rerun of the
// completed checks, and never grants another automatic retry: review 3 ending invalid stops
// without a review 4, and one more explicit resume approves and lands.
func TestKReviewRetryReviewOnlyResume(t *testing.T) {
	t.Parallel()
	bin := buildKogen(t)
	e := newEnv(t)
	id := e.stopAfterTwoInvalidReviews(bin)
	f := e.prov
	_, state := e.checkpoint(id)
	cont := state["continuation"].(map[string]any)
	eq(t, "checkpoint stage", cont["stage"], any("review_only"))
	eq(t, "preserved green tree", cont["pass"].(map[string]any)["tree"], any(treeOfCandidate(e)))
	eq(t, "candidate preserved", e.read("app.txt"), "candidate\n")
	eq(t, "review-only outcome", e.result(id)["outcome"], any("review_invalid"))
	eq(t, "reviews so far", e.result(id)["reviews"], any(float64(2)))
	eq(t, "passes so far", e.result(id)["passes"], any(float64(1)))
	facts := e.jsonFile(filepath.Join(e.root, ".kogen/local/facts", id+".json"))
	eq(t, "resume status", facts["resume_status"], any("potentially_available"))
	start := e.head()
	before := f.count()

	// Review 3 ends invalid: no automatic review 4.
	f.then(prose("a"), prose("b"))
	code, out := e.cli(bin, "intent", "resume", id)
	if code != 1 || !strings.Contains(out, "candidate/review_invalid") {
		t.Fatalf("resume exit %d\n%s", code, out)
	}
	eq(t, "head", e.head(), start)
	eq(t, "requests of review 3 only", f.count()-before, 2)
	eq(t, "review requests", len(f.reviewRequests()), 7)
	second := buildIDOf.FindStringSubmatch(out)[1]
	if second == id {
		t.Fatal("the resume reused the stopped run")
	}
	_, state = e.checkpoint(second)
	eq(t, "stage", state["continuation"].(map[string]any)["stage"], any("review_only"))
	rr := state["review_retry"].(map[string]any)
	eq(t, "automatic spent", rr["automatic"], any(true))
	lineage := rr["invalid"].([]any)
	eq(t, "lineage", len(lineage), 3)
	last := lineage[2].(map[string]any)
	eq(t, "review 3 reason", last["reason"], any("no_tool_reminder_exhausted"))
	eq(t, "review 3 stopped", last["next"], any("stop"))
	eq(t, "review 3 run", last["run"], any(second))
	eq(t, "reviews", e.result(second)["reviews"], any(float64(3)))

	// A further explicit resume is allowed: review 4 approves the unchanged candidate.
	before = f.count()
	f.then(submit(f, "approve", finding("note", "fine")))
	code, out = e.cli(bin, "intent", "resume", second)
	if code != 0 {
		t.Fatalf("second resume exit %d\n%s", code, out)
	}
	contains(t, "stdout", out, "landed "+testSlug+" ")
	eq(t, "commits", e.commitsSince(start), "1")
	eq(t, "committed", e.gitOut("show", "HEAD:app.txt"), "candidate")
	// One new request, the fresh review: the builder did not run again.
	eq(t, "requests", f.count()-before, 1)
	reqs := f.reviewRequests()
	eq(t, "review requests", len(reqs), 8)
	fourth := reqs[7]
	eq(t, "fresh conversation", len(requestInput(fourth)), 1)
	eq(t, "same material", jsonOf(requestInput(fourth)[0]), jsonOf(requestInput(reqs[0])[0]))
	eq(t, "same rules", requestInstructions(fourth), requestInstructions(reqs[0]))
	eq(t, "same tools", jsonOf(fourth["tools"]), jsonOf(reqs[0]["tools"]))
	for i := 0; i < 7; i++ {
		if cacheKey(reqs[i]) == cacheKey(fourth) {
			t.Fatalf("review 4 reused the conversation identity of request %d", i)
		}
	}
	lacks(t, "review 4", requestText(fourth), "function_call")
	var third string
	for _, run := range e.runIDs() {
		if run != id && run != second {
			third = run
		}
	}
	res := e.result(third)
	eq(t, "outcome", res["outcome"], any("landed"))
	eq(t, "resumed from", res["resumed_from"], any(second))
	eq(t, "reviews", res["reviews"], any(float64(4)))
	eq(t, "no new pass", res["passes"], any(float64(1)))
	events := e.events(third)
	for _, name := range []string{"pass", "command", "command_result", "executor_round"} {
		eq(t, name+" events in the resumed run", len(eventsNamed(events, name)), 0)
	}
	retries := eventsNamed(events, "review_retry")
	eq(t, "retry events", len(retries), 1)
	eq(t, "retry kind", retries[0]["kind"], any("resume"))
	eq(t, "retry parent", retries[0]["parent"], any(second))
	eq(t, "retry from", retries[0]["from_review"], any(float64(3)))
	eq(t, "retry to", retries[0]["review"], any(float64(4)))
	invalid := retries[0]["invalid_reviews"].([]any)
	var reasons []any
	for _, i := range invalid {
		reasons = append(reasons, i.(map[string]any)["reason"])
	}
	eq(t, "lineage reasons", reasons, []any{"no_tool_reminder_exhausted", "rejected_verdict_exhausted", "no_tool_reminder_exhausted"})
	verdicts := eventsNamed(events, "review")
	eq(t, "verdict events", len(verdicts), 1)
	eq(t, "approved review", verdicts[0]["review"], any(float64(4)))
	eq(t, "approved", verdicts[0]["verdict"], any("approve"))
	approved := e.jsonFile(e.runPath(third, "review-4.json"))
	eq(t, "review-4 tree", approved["tree"], any(e.gitOut("rev-parse", "HEAD^{tree}")))
	// The earlier runs keep their own failed results.
	eq(t, "first outcome", e.result(id)["outcome"], any("review_invalid"))
	eq(t, "second outcome", e.result(second)["outcome"], any("review_invalid"))
}

// treeOfCandidate is the tree of the checkout's current candidate (start HEAD plus the files
// the Build left, excluding nothing for this fixture).
func treeOfCandidate(e *env) string {
	repo := e.gitRepo()
	tree, err := repo.Tree(e.gitOut("rev-parse", "HEAD"), nil)
	if err != nil {
		e.t.Fatal(err)
	}
	return tree
}

// TestKReviewRetryChangedCheckout: a changed candidate refuses the review-only resume through
// the real command with no provider request, no run, no build round, no commit and nothing in
// the files, index, HEAD or approval touched; the unchanged control resumes. One stopped Build
// serves every case: each drift is undone after its refusal, so the checkout is the stopped one
// every time.
func TestKReviewRetryChangedCheckout(t *testing.T) {
	t.Parallel()
	bin := buildKogen(t)
	e := newEnv(t)
	id := e.stopAfterTwoInvalidReviews(bin)
	appPath := filepath.Join(e.root, "app.txt")
	indexPath := filepath.Join(e.root, ".git", "index")
	index, err := os.ReadFile(indexPath)
	if err != nil {
		t.Fatal(err)
	}
	restoreIndex := func() {
		if err := os.WriteFile(indexPath, index, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	refused := func(name string, wantLine string) {
		t.Helper()
		before, requests := e.snapshot(), e.prov.count()
		code, out := e.cli(bin, "intent", "resume", id)
		if code != 1 || !strings.Contains(out, wantLine) {
			t.Fatalf("%s: exit %d, want a refusal with %q\n%s", name, code, wantLine, out)
		}
		eq(t, name+": provider requests", e.prov.count(), requests)
		after := e.snapshot()
		eq(t, name+": files", after.files, before.files)
		eq(t, name+": index", after.index, before.index)
		eq(t, name+": HEAD", after.head, before.head)
		eq(t, name+": approval", after.approval, before.approval)
		eq(t, name+": runs", after.runs, before.runs)
		eq(t, name+": no commit", e.commitsSince(before.head), "0")
		if after.approval == "" {
			t.Fatal("the approval record was not part of the observed custody")
		}
		if len(eventsNamed(e.events(id), "resume")) != 0 {
			t.Fatal("the refused resume wrote to the stopped run")
		}
	}

	// No command-line option was added.
	before, requests := e.snapshot(), e.prov.count()
	code, _ := e.cli(bin, "intent", "resume", id, "--review-only")
	eq(t, "usage exit", code, 2)
	eq(t, "provider requests", e.prov.count(), requests)
	eq(t, "files", e.snapshot().files, before.files)

	for _, drift := range []struct {
		name, line  string
		apply, undo func()
	}{
		{"changed candidate file", "candidate/resume_refused: Build " + id + ": candidate contents/modes or unrelated paths changed: app.txt",
			func() { e.write("app.txt", "changed after the stop\n") }, func() { e.write("app.txt", "candidate\n") }},
		{"added file", "resume_refused", func() { e.write("extra.txt", "x\n") }, func() { os.Remove(filepath.Join(e.root, "extra.txt")) }},
		{"mode", "resume_refused", func() { os.Chmod(appPath, 0o755) }, func() { os.Chmod(appPath, 0o644) }},
		{"staged file", "resume_refused", func() { e.write("staged.txt", "x\n"); e.run("git", "add", "staged.txt") },
			func() { os.Remove(filepath.Join(e.root, "staged.txt")); restoreIndex() }},
		{"HEAD moved", "resume_refused", func() { e.run("git", "commit", "-q", "--allow-empty", "-m", "elsewhere") },
			func() { e.run("git", "reset", "-q", "--soft", "HEAD~1"); restoreIndex() }},
	} {
		drift.apply()
		refused(drift.name, drift.line)
		drift.undo()
	}

	// The unchanged checkout resumes.
	f := e.prov
	f.then(submit(f, "approve"))
	start := e.head()
	code, out := e.cli(bin, "intent", "resume", id)
	if code != 0 {
		t.Fatalf("control resume exit %d\n%s", code, out)
	}
	eq(t, "commits", e.commitsSince(start), "1")
}

package build

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"

	"kogen-loop/sys"
	"kogen/project"
)

// Recovery of a builder-reported protected blocker (`kogen intent recover`).

// blocked is a repository whose Build stopped on a builder-reported blocker after the shell
// commands ran; the checkout holds the implementation the builder left.
func blocked(t *testing.T, commands string) (*env, string) {
	t.Helper()
	e := newEnv(t)
	e.write("locked/value", "before\n")
	e.write("filtered", "before\n")
	e.write(".gitattributes", "filtered filter=normalize\n")
	e.run("git", "config", "filter.normalize.clean", "tr a-z A-Z")
	e.run("git", "add", "locked/value", "filtered", ".gitattributes")
	e.run("git", "commit", "-qm", "Recovery inputs")
	e.write(".git/info/exclude", "ignored/\n")
	f := e.prov
	f.then(f.calls("shell", map[string]any{"command": commands}, "report_blocker", blockerReport(project.FeaturePath(testSlug))))
	a := e.build()
	if a.exit != 1 {
		t.Fatalf("exit %d\n%s", a.exit, a.shown())
	}
	contains(t, "stdout", a.out.String(), "candidate/build_blocked")
	return e, e.onlyRun()
}

func (e *env) recover(id, output string) *attempt {
	e.t.Helper()
	s, out, errs := e.session()
	a := &attempt{s: s, out: out, errs: errs, e: e}
	a.exit, a.err = Recover(context.Background(), s, RecoverInput{Project: e.root, ID: id, Output: output})
	if a.err != nil {
		a.exit = 1
		if se, ok := sys.AsError(a.err); ok {
			a.exit = se.Exit
		}
	}
	return a
}

func TestRecoveryArchivesRawFilteredBinaryModeSymlinkAndDeletedPathsWithoutIndexOrIgnoredChanges(t *testing.T) {
	// ExUnit: test/integration/recovery_test.exs: raw filtered bytes, binary, executable modes, symlink targets and deleted paths are archived without index or ignored-output changes
	e, id := blocked(t, "printf 'candidate raw\n' > filtered; printf '\\000\\377' > binary; chmod +x filtered; rm locked/value; ln -s filtered link; mkdir -p ignored; printf warm > ignored/cache")
	output := filepath.Join(physical(t, t.TempDir()), "raw archive")
	index, _ := os.ReadFile(filepath.Join(e.root, ".git/index"))
	r := e.recover(id, output)
	if r.exit != 0 || r.err != nil {
		t.Fatalf("exit %d\n%s", r.exit, r.shown())
	}
	var manifest struct {
		Changes []struct {
			Path  string
			After *RawMeta
		}
		Artifacts []struct{ Path string }
	}
	data, err := os.ReadFile(filepath.Join(output, "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, &manifest); err != nil {
		t.Fatal(err)
	}
	read := func(p string) string {
		b, err := os.ReadFile(filepath.Join(output, p))
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	eq(t, "candidate filtered", read("candidate/filtered"), "candidate raw\n")
	eq(t, "before filtered", read("before/filtered"), "BEFORE\n")
	eq(t, "candidate binary", read("candidate/binary"), "\x00\xff")
	eq(t, "candidate link", read("candidate/link"), "filtered")
	if st, _ := os.Lstat(filepath.Join(output, "candidate/link")); !st.Mode().IsRegular() {
		t.Fatal("the symbolic link was archived as a link")
	}
	modes := map[string]*RawMeta{}
	for _, c := range manifest.Changes {
		modes[c.Path] = c.After
	}
	eq(t, "filtered mode", modes["filtered"].Mode, "100755")
	eq(t, "link mode", modes["link"].Mode, "120000")
	eq(t, "filtered restored", e.read("filtered"), "BEFORE\n")
	if st, _ := os.Stat(filepath.Join(e.root, "filtered")); st.Mode().Perm()&0o111 != 0 {
		t.Fatal("the executable bit stayed")
	}
	eq(t, "deleted restored", e.read("locked/value"), "before\n")
	if _, err := os.Stat(filepath.Join(e.root, "binary")); !os.IsNotExist(err) {
		t.Fatal("binary stayed")
	}
	if _, err := os.Lstat(filepath.Join(e.root, "link")); !os.IsNotExist(err) {
		t.Fatal("link stayed")
	}
	eq(t, "ignored output", e.read("ignored/cache"), "warm")
	after, _ := os.ReadFile(filepath.Join(e.root, ".git/index"))
	eq(t, "index", string(after), string(index))
	var paths []string
	for _, a := range manifest.Artifacts {
		paths = append(paths, a.Path)
	}
	sorted := append([]string(nil), paths...)
	slices.Sort(sorted)
	eq(t, "artifacts sorted", paths, sorted)
	receipt := e.jsonFile(filepath.Join(e.root, ".kogen/local/recoveries", id+".json"))
	eq(t, "receipt", receipt["state"], any("cleaned"))
	eq(t, "receipt archive", receipt["archive"], any(output))
	for _, name := range []string{"index-at-start", "approval.json", "checkpoint.json", "result.json", "blocker.json", "correction.md", "context.md", "manifest.json"} {
		if st, err := os.Stat(filepath.Join(output, name)); err != nil || st.Mode().Perm() != 0o600 {
			t.Fatalf("%s: %v", name, err)
		}
	}
	if st, _ := os.Stat(output); st.Mode().Perm() != 0o700 {
		t.Fatalf("archive mode %v", st.Mode().Perm())
	}
	out := r.out.String()
	contains(t, "stdout", out, "Preserved "+output+"/manifest.json SHA-256 ")
	contains(t, "stdout", out, "kogen intent refine fixture ")
	contains(t, "stdout", out, shellQuote(filepath.Join(output, "correction.md")))
	contains(t, "stdout", out, "Review the corrected package and freshly approve its new exact hash:\n")
	contains(t, "stdout", out, "kogen intent approve fixture --project "+shellQuote(e.root)+"\n")
	contains(t, "stdout", out, "kogen intent approve fixture <new-full-sha256> --project "+shellQuote(e.root)+"\n")
	contains(t, "stdout", out, "Then start a FRESH Build:\n")
	contains(t, "stdout", out, "kogen intent build fixture --context "+shellQuote(filepath.Join(output, "context.md"))+" --project "+shellQuote(e.root)+"\n")
	handoff := read("correction.md")
	eq(t, "context is the handoff", read("context.md"), handoff)
	contains(t, "handoff", handoff, "BUILDER-REPORTED and unproven.")
	contains(t, "handoff", handoff, "no approval, resume, import or reuse of old green evidence.")
}

func TestRecoveryOfFileDirectoryReplacementsPreservesBothLeafSetsAndCleansOnlyTheDelta(t *testing.T) {
	// ExUnit: test/integration/recovery_test.exs: file-directory replacements preserve both leaf sets and clean only the delta
	e, id := blocked(t, "rm app.txt; mkdir app.txt; printf nested > app.txt/child; rm locked/value; rmdir locked; printf replacement > locked")
	output := filepath.Join(physical(t, t.TempDir()), "transitions")
	index, _ := os.ReadFile(filepath.Join(e.root, ".git/index"))
	r := e.recover(id, output)
	if r.exit != 0 {
		t.Fatalf("exit %d\n%s", r.exit, r.shown())
	}
	read := func(p string) string {
		b, err := os.ReadFile(filepath.Join(output, p))
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	eq(t, "before app", read("before/app.txt"), "baseline\n")
	eq(t, "candidate child", read("candidate/app.txt/child"), "nested")
	eq(t, "before locked", read("before/locked/value"), "before\n")
	eq(t, "candidate locked", read("candidate/locked"), "replacement")
	eq(t, "app restored", e.read("app.txt"), "baseline\n")
	eq(t, "locked restored", e.read("locked/value"), "before\n")
	after, _ := os.ReadFile(filepath.Join(e.root, ".git/index"))
	eq(t, "index", string(after), string(index))
	contains(t, "stdout", r.out.String(), "--project "+shellQuote(e.root))
}

func TestRecoveryPublicationPrecedesACleanupWriteFailureAndTheReceiptStaysPreserved(t *testing.T) {
	// ExUnit: test/integration/recovery_test.exs: publication precedes a controlled local cleanup write failure; candidate rollback and preserved receipt remain honest
	e, id := blocked(t, "printf candidate > app.txt; printf after > locked/value")
	locked := filepath.Join(e.root, "locked")
	os.Chmod(locked, 0o555)
	t.Cleanup(func() { os.Chmod(locked, 0o755) })
	if err := os.WriteFile(filepath.Join(locked, "write-probe"), []byte("probe"), 0o644); err == nil {
		os.Remove(filepath.Join(locked, "write-probe"))
		t.Skip("the caller bypasses directory modes (root)")
	}
	output := filepath.Join(physical(t, t.TempDir()), "archive")
	index, _ := os.ReadFile(filepath.Join(e.root, ".git/index"))
	approval, _ := os.ReadFile(project.ApprovalPath(e.root, testSlug))
	requests := e.prov.count()
	r := e.recover(id, output)
	eq(t, "exit", r.exit, 1)
	text := r.shown()
	contains(t, "output", text, "cleanup incomplete")
	contains(t, "output", text, "candidate bytes restored")
	eq(t, "archived candidate", func() string { b, _ := os.ReadFile(filepath.Join(output, "candidate/app.txt")); return string(b) }(), "candidate")
	eq(t, "app", e.read("app.txt"), "candidate")
	eq(t, "locked", e.read("locked/value"), "after")
	receipt := e.jsonFile(filepath.Join(e.root, ".kogen/local/recoveries", id+".json"))
	eq(t, "state", receipt["state"], any("preserved"))
	eq(t, "archive", receipt["archive"], any(output))
	after, _ := os.ReadFile(filepath.Join(e.root, ".git/index"))
	eq(t, "index", string(after), string(index))
	gotApproval, _ := os.ReadFile(project.ApprovalPath(e.root, testSlug))
	eq(t, "approval", string(gotApproval), string(approval))
	eq(t, "requests", e.prov.count(), requests)
	if _, err := os.Stat(filepath.Join(output, "manifest.json")); err != nil {
		t.Fatal(err)
	}
}

func TestRecoveryRefusals(t *testing.T) {
	t.Parallel()
	// ExUnit: lib/kogen/recover.ex (every named custody fact is checked before anything is written, and again before cleanup)
	type refusal struct {
		name   string
		id     func(e *env, id string) string
		prep   func(e *env, id string)
		output func(e *env) string
		want   string
		kind   string
	}
	cases := []refusal{
		{name: "unknown id", id: func(*env, string) string { return "nothex" }, want: "unknown checkpoint", kind: "recovery_unsupported"},
		{name: "absent checkpoint", id: func(*env, string) string { return "00000000" }, want: "absent checkpoint", kind: "recovery_unsupported"},
		{name: "version 2", prep: func(e *env, id string) {
			doc, _ := e.checkpoint(id)
			doc["version"] = float64(2)
			e.writeCheckpoint(id, doc)
		}, want: "legacy checkpoint version 2", kind: "recovery_unsupported"},
		{name: "head moved", prep: func(e *env, id string) { e.run("git", "commit", "-q", "--allow-empty", "-m", "moved") }, want: "HEAD changed"},
		{name: "index changed", prep: func(e *env, id string) { e.write("staged.txt", "x\n"); e.run("git", "add", "staged.txt") }, want: "index changed"},
		{name: "approval changed", prep: func(e *env, id string) {
			e.write(".kogen/local/approvals/fixture.json", strings.Replace(e.read(".kogen/local/approvals/fixture.json"), "Kogen Integration", "Somebody", 1))
		}, want: "approval changed"},
		{name: "protected file changed", prep: func(e *env, id string) { e.write(stepsFile, "// changed\n") }, want: "protected baseline changed: " + stepsFile},
		{name: "candidate changed", prep: func(e *env, id string) { e.write("app.txt", "drift\n") }, want: "complete stopped candidate changed"},
		{name: "unrecorded path", prep: func(e *env, id string) { e.write("other.txt", "x\n") }, want: "complete stopped candidate changed"},
		{name: "index backup changed", prep: func(e *env, id string) {
			os.WriteFile(e.runPath(id, "index-at-start"), []byte("damaged"), 0o644)
		}, want: "original index backup changed"},
		{name: "result differs", prep: func(e *env, id string) {
			res := e.result(id)
			res["outcome"] = "interrupted"
			b, _ := json.Marshal(res)
			os.WriteFile(e.runPath(id, "result.json"), b, 0o644)
		}, want: "result does not match completed build_blocked report"},
		{name: "output exists", output: func(e *env) string { return e.aux }, want: "output destination already exists or is unsafe: "},
		{name: "output inside the checkout", output: func(e *env) string { return filepath.Join(e.root, "archive") }, want: "output destination is inside checkout"},
		{name: "receipt exists", prep: func(e *env, id string) {
			os.MkdirAll(filepath.Join(e.root, ".kogen/local/recoveries"), 0o700)
			os.WriteFile(filepath.Join(e.root, ".kogen/local/recoveries", id+".json"), []byte("{}"), 0o600)
		}, want: "existing recovery receipt or unsafe custody: "},
		{name: "raw identity", prep: func(e *env, id string) {
			doc, _ := e.checkpoint(id)
			doc["recovery_raw"] = map[string]any{}
			e.writeCheckpoint(id, doc)
		}, want: "raw candidate identity changed or missing"},
		{name: "unsafe parent of the output", output: func(e *env) string {
			link := filepath.Join(physical(t, t.TempDir()), "link")
			os.Symlink(e.aux, link)
			return filepath.Join(link, "archive")
		}, want: "unsafe/symlinked or missing custody: "},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			e, id := blocked(t, "printf candidate > app.txt")
			if c.prep != nil {
				c.prep(e, id)
			}
			use := id
			if c.id != nil {
				use = c.id(e, id)
			}
			output := filepath.Join(physical(t, t.TempDir()), "archive")
			if c.output != nil {
				output = c.output(e)
			}
			state, files := e.state(), e.runFiles(id)
			r := e.recover(use, output)
			eq(t, "exit", r.exit, 1)
			kind := c.kind
			if kind == "" {
				kind = "recovery_refused"
			}
			text := r.shown()
			contains(t, "output", text, "candidate/"+kind+": "+c.want)
			contains(t, "output", text, "; inspect the run/receipt and checkout; correct the named fact or use ordinary Refine and fresh exact approval")
			if !reflect.DeepEqual(e.state(), state) || !reflect.DeepEqual(e.runFiles(id), files) {
				t.Fatal("custody changed")
			}
			if c.output == nil && c.name != "unknown id" {
				if _, err := os.Stat(output); err == nil {
					t.Fatal("an archive was written")
				}
			}
		})
	}
}

func TestRecoveryRefusesABuildThatReportedNoBlocker(t *testing.T) {
	// ExUnit: lib/kogen/recover.ex (only a completed BUILDER-REPORTED blocker is recoverable)
	e := newEnv(t)
	f := e.prov
	f.then(f.calls("finish", map[string]any{"summary": "done"}))
	e.build()
	id := e.onlyRun()
	r := e.recover(id, filepath.Join(physical(t, t.TempDir()), "archive"))
	eq(t, "exit", r.exit, 1)
	contains(t, "output", r.shown(), "candidate/recovery_refused: not a BUILDER-REPORTED protected blocker;")
}

func TestARecoveredBlockerCannotBeResumedAndRecoversOnlyOnce(t *testing.T) {
	// ExUnit: lib/kogen/recover.ex (the receipt makes a second recovery impossible; resume cannot override a protected blocker)
	e, id := blocked(t, "printf candidate > app.txt")
	output := filepath.Join(physical(t, t.TempDir()), "archive")
	if r := e.recover(id, output); r.exit != 0 {
		t.Fatalf("exit %d\n%s", r.exit, r.shown())
	}
	again := e.recover(id, filepath.Join(physical(t, t.TempDir()), "second"))
	eq(t, "second exit", again.exit, 1)
	contains(t, "second", again.shown(), "existing recovery receipt or unsafe custody: "+id+".json; inspect receipt instead")
	r := e.resume(id)
	eq(t, "resume exit", r.exit, 1)
	contains(t, "resume", r.shown(), "candidate/resume_refused: Build "+id+": ")
}

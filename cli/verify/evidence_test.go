package verify

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"kogen-loop/sys"
	"kogen/project"
)

func (p *proj) setFeasibility(ds ...Declaration) {
	p.t.Helper()
	lines := make([]string, len(ds))
	for i, d := range ds {
		lines[i] = "- evidence: " + encode(d)
	}
	writeIntent(p.fixture, "not applicable — nothing to model", strings.Join(lines, "\n"))
	intent, _, err := project.CheckIntent(p.Root, fixtureSlug, nil)
	if err != nil {
		p.t.Fatal(err)
	}
	p.Intent = intent
}

func capability(id, command string, exit int, output string, inputs ...string) Declaration {
	return Declaration{ID: id, Kind: "capability", Inputs: inputs, Observers: []string{},
		Checks: []DeclaredCheck{{Name: "support", Command: command, Exit: exit, Output: output}}}
}

func (p *proj) retained() []map[string]any {
	b, err := os.ReadFile(filepath.Join(p.Root, ".kogen/local/readiness/"+fixtureSlug+"-feasibility.ndjson"))
	if err != nil {
		return nil
	}
	var out []map[string]any
	for _, line := range strings.Split(strings.TrimSpace(string(b)), "\n") {
		var rec []any
		if err := json.Unmarshal([]byte(line), &rec); err != nil {
			p.t.Fatal(err)
		}
		for _, o := range rec {
			out = append(out, o.(map[string]any))
		}
	}
	return out
}

func TestExecuteRunsDeclaredChecksInAProbeCopyAndRetainsTheActualOutcome(t *testing.T) {
	tmp := isolateTmp(t)
	p := newProj(t)
	p.write("route.cjs", "route bytes\n")
	d := capability("route", "cat route.cjs; echo extra >> route.log; exit 23", 23, "route bytes\n", "route.cjs")
	p.setFeasibility(d)
	ev := newEvidence()
	s, _ := p.session()
	got, err := Execute(context.Background(), s, Tools{}, p.Root, p.Intent, p.Root, ev)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].ID != "route" || got[0].Checks[0].Exit != 23 || got[0].Checks[0].TimedOut || got[0].Inputs["route.cjs"] != sha("route bytes\n") {
		t.Fatalf("obligations = %s", encode(got))
	}
	if !Valid(p.Root, p.Intent, got) {
		t.Fatal("the executed evidence is valid proof")
	}
	eq(t, "probes", ev.probes, 1)
	eq(t, "recorded events", len(ev.events), 1)
	eq(t, "event", ev.events[0]["event"].(string), "feasibility_check")
	// The obligation of the event is its identity (no checks); the check is the actual outcome.
	obligation := ev.events[0]["obligation"].(map[string]any)
	eq(t, "obligation keys", len(obligation), 4)
	eq(t, "obligation inputs", obligation["inputs"].(map[string]any)["route.cjs"].(string), sha("route bytes\n"))
	check := ev.events[0]["check"].(map[string]any)
	eq(t, "check name", check["name"].(string), "support")
	eq(t, "check timed_out", check["timed_out"].(bool), false)
	eq(t, "retained", len(p.retained()), 1)
	// The probe ran in a copy: nothing leaked into the checkout, nothing is left in /tmp.
	if fileExists(filepath.Join(p.Root, "route.log")) {
		t.Fatal("the probe wrote into the checkout")
	}
	requireNoLeftovers(t, tmp)
	// Every execution appends one line.
	if _, err := Execute(context.Background(), s, Tools{}, p.Root, p.Intent, p.Root, nil); err != nil {
		t.Fatal(err)
	}
	eq(t, "retained after two runs", len(p.retained()), 2)
}

// ExUnit: readiness_observations_test.exs, replacement bytes inside the disposable probe.
func TestDeclaredChecksCannotQualifyReplacementBytesInsideTheirDisposableProbe(t *testing.T) {
	isolateTmp(t)
	p := newProj(t)
	observer := "features/steps/observed_steps.js"
	source := "reject submitted bytes\n"
	input := "control.txt"
	p.write(input, source)
	p.write(observer, "observer bytes\n")
	for _, path := range []string{observer, input} {
		d := Declaration{ID: "final-bytes", Kind: "capability", Inputs: []string{observer, input}, Observers: []string{},
			Checks: []DeclaredCheck{{Name: "support", Command: "printf 'replacement\\n' > " + path + "; printf 'accepted\\n'", Exit: 0, Output: "accepted\n"}}}
		p.setFeasibility(d)
		observerBytes := p.read(observer)
		s, _ := p.session()
		_, err := Execute(context.Background(), s, Tools{}, p.Root, p.Intent, p.Root, nil)
		e := failWith(t, err, "intent", "not_ready")
		eq(t, "detail", e.Detail, "declared feasibility evidence failed")
		joined := strings.Join(e.Lines, "\n")
		contains(t, "lines", joined, "final-bytes/support")
		contains(t, "lines", joined, path)
		contains(t, "lines", joined, `"input_changes":["`+path+`"]`)
		var found bool
		for _, r := range p.retained() {
			if strings.Contains(encode(r), "accepted") {
				found = true
			}
		}
		if !found {
			t.Fatal("the actual outcome is retained")
		}
		eq(t, "input", p.read(input), source)
		eq(t, "observer", p.read(observer), observerBytes)
	}
}

// ExUnit: readiness_observations_test.exs, feedback bounded across obligations.
func TestFeasibilityFeedbackIsBoundedAcrossObligationsWhileFullFailuresRemainInspectable(t *testing.T) {
	isolateTmp(t)
	p := newProj(t)
	p.write("app.txt", "x")
	cmd := `yes é | head -n 10000 | tr -d '\n'`
	p.setFeasibility(capability("first-control", cmd, 0, "supported\n", "app.txt"), capability("last-control", cmd, 0, "supported\n", "app.txt"))
	s, _ := p.session()
	_, err := Execute(context.Background(), s, Tools{}, p.Root, p.Intent, p.Root, nil)
	e := failWith(t, err, "intent", "not_ready")
	text := e.Render()
	if !utf8.ValidString(text) || len(text) >= 17000 {
		t.Fatalf("feedback: %d bytes, valid %v", len(text), utf8.ValidString(text))
	}
	contains(t, "feedback", text, "first-control/support")
	contains(t, "feedback", text, "bytes omitted")
	retained := p.retained()
	eq(t, "retained obligations", len(retained), 2)
	for i, id := range []string{"first-control", "last-control"} {
		eq(t, "id", retained[i]["id"].(string), id)
		eq(t, "full output kept", retained[i]["checks"].([]any)[0].(map[string]any)["output"].(string), strings.Repeat("é", 10000))
	}
	if fileExists(readinessPath(p.Root, fixtureSlug)) {
		t.Fatal("no readiness record for failed evidence")
	}
}

func TestReadinessRunsDeclaredEvidenceAndRecordsItsProof(t *testing.T) {
	isolateTmp(t)
	p := newProj(t)
	p.write("route.cjs", "route bytes\n")
	p.setFeasibility(capability("route", "cat route.cjs", 0, "route bytes\n", "route.cjs"))
	p.commit("evidence")
	r := p.readiness()
	s, _ := p.session()
	ready, err := r.Check(context.Background(), s, fixtureSlug)
	if err != nil {
		t.Fatal(err)
	}
	eq(t, "obligations", len(ready.Feasibility), 1)
	rec, _ := p.readinessRecord()
	if feas := rec["feasibility"].([]any); len(feas) != 1 || feas[0].(map[string]any)["id"] != "route" {
		t.Fatalf("record = %v", rec)
	}
	if r.Cached(s, fixtureSlug) == nil {
		t.Fatal("evidence with proof is reusable")
	}
	// A declaration whose check no longer holds is not ready, and the record is gone.
	p.setFeasibility(capability("route", "cat route.cjs", 0, "other\n", "route.cjs"))
	_, err = r.Check(context.Background(), s, fixtureSlug)
	e := failWith(t, err, "intent", "not_ready")
	eq(t, "detail", e.Detail, "declared feasibility evidence failed")
	if fileExists(readinessPath(p.Root, fixtureSlug)) {
		t.Fatal("record must be gone")
	}
}

func TestCopyTreeKeepsIgnoredFilesAndLeavesOutGitAndLocalState(t *testing.T) {
	p := newProj(t)
	p.write("build/out.txt", "ignored output")
	p.write(".kogen/local/runs/x/log", "local")
	p.write("node_modules/dep/index.js", "dep")
	scratch := filepath.Join(t.TempDir(), "copy")
	os.MkdirAll(scratch, 0o755)
	if err := CopyTree(p.Root, scratch); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"app.txt", "build/out.txt", "node_modules/dep/index.js", ".kogen/project.yaml", ".kogen/intents/fixture/intent.md", ".gitignore"} {
		if !fileExists(filepath.Join(scratch, want)) {
			t.Errorf("copy lacks %s", want)
		}
	}
	for _, not := range []string{".git", ".kogen/local"} {
		if fileExists(filepath.Join(scratch, not)) {
			t.Errorf("copy has %s", not)
		}
	}
}

func TestRunProbeReportsStatusOutputWallAndInputChanges(t *testing.T) {
	isolateTmp(t)
	p := newProj(t)
	p.write("a.txt", "a")
	s, _ := p.session()
	r, err := RunProbe(context.Background(), s, p.Root, "echo out; echo err >&2; printf b > a.txt; exit 5", map[string]string{"a.txt": sha("a"), "missing.txt": sha("x")})
	if err != nil {
		t.Fatal(err)
	}
	eq(t, "status", r.Status, 5)
	eq(t, "timed out", r.TimedOut, false)
	eq(t, "output", len(r.Output) == len("out\nerr\n") || strings.Contains(r.Output, "out"), true)
	eqSlice(t, "input changes", r.InputChanges, []string{"a.txt", "missing.txt"})
	eq(t, "checkout untouched", p.read("a.txt"), "a")
}

func TestReadinessInterruptStopsAndCleansUp(t *testing.T) {
	tmp := isolateTmp(t)
	p := newProj(t)
	p.Config.Setup = []string{"touch '" + p.trace("started") + "'; sleep 30"}
	s, _ := p.session()
	go func() {
		for i := 0; i < 400; i++ {
			if fileExists(p.trace("started")) {
				s.Interrupt("SIGTERM")
				return
			}
			time.Sleep(25 * time.Millisecond)
		}
	}()
	_, err := p.readiness().Check(context.Background(), s, fixtureSlug)
	var intr *sys.Interrupted
	if !errors.As(err, &intr) || intr.Signal != "SIGTERM" {
		t.Fatalf("err = %v, want an interrupt", err)
	}
	requireNoLeftovers(t, tmp)
	if fileExists(readinessPath(p.Root, fixtureSlug)) {
		t.Fatal("no record after an interrupt")
	}
}

func TestProbeFilesStayInTheScratchCopyAndThePrepareStep(t *testing.T) {
	isolateTmp(t)
	p := newProj(t)
	if err := os.Symlink("elsewhere", filepath.Join(p.Root, "link")); err != nil {
		t.Fatal(err)
	}
	p.write("blocker", "a file")
	s, _ := p.session()
	s.Env = append(s.Env, "KOGEN_FROM_CALLER=yes")
	pr := Probe{Root: p.Root, Command: `cat probe/new.txt app.txt; echo "$KOGEN_NODE $KOGEN_FROM_CALLER"`, Tools: Tools{Node: "/n/node"},
		Files: []ProbeFile{{Path: "probe/new.txt", Content: "overlay\n"}, {Path: "app.txt", Content: "replaced\n"}}}
	got, err := pr.Run(context.Background(), s)
	if err != nil {
		t.Fatal(err)
	}
	eq(t, "output", got.Output, "overlay\nreplaced\n/n/node \n")
	eq(t, "checkout untouched", p.read("app.txt"), "green\n")
	if fileExists(filepath.Join(p.Root, "probe")) {
		t.Fatal("the overlay leaked into the checkout")
	}
	for _, tc := range []struct {
		file    ProbeFile
		problem string
	}{
		{ProbeFile{Path: "../outside.txt"}, "../outside.txt is outside the scratch copy"},
		{ProbeFile{Path: "/etc/kogen-probe-test"}, "/etc/kogen-probe-test is outside the scratch copy"},
		{ProbeFile{Path: "link/x.txt"}, "link/x.txt would be written through a symlink"},
		{ProbeFile{Path: "blocker/x.txt"}, "blocker/x.txt: enotdir"},
		{ProbeFile{Path: ".kogen"}, ".kogen: eisdir"},
	} {
		_, err := Probe{Root: p.Root, Command: "true", Files: []ProbeFile{tc.file}}.Run(context.Background(), s)
		var fe *ProbeFileError
		if !errors.As(err, &fe) || len(fe.Problems) != 1 || fe.Problems[0] != tc.problem {
			t.Fatalf("%q: err = %v, want %q", tc.file.Path, err, tc.problem)
		}
		eq(t, "message", err.Error(), "error: "+tc.problem)
	}
	_, err = Probe{Root: p.Root, Command: "true", Files: []ProbeFile{{Path: "../a"}, {Path: "link/b"}}}.Run(context.Background(), s)
	eq(t, "all problems in one message", err.Error(), "error: ../a is outside the scratch copy; link/b would be written through a symlink")
}

// A probe runs in a session of its own whose environment is built by allowlist: the caller's
// credentials and credential-store paths never reach it, and its HOME is a private empty
// folder, not the caller's home.
func TestShapeProbeMinimalEnvironment(t *testing.T) {
	tmp := isolateTmp(t)
	p := newProj(t)
	callerHome := t.TempDir()
	store := filepath.Join(callerHome, ".kogen", "credentials")
	if err := os.MkdirAll(store, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(store, "chatgpt.json"), []byte(`{"token":"synthetic-saved-login"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	s := sys.NewWith(testEnv("HOME="+callerHome, "STUDIO_TOKEN=studio-secret", "OPENAI_API_KEY=openai-secret",
		"UNRELATED_SECRET=unrelated-secret", "KOGEN_CREDENTIALS_DIR="+store, "NODE_OPTIONS=--require=/x", "BASH_ENV=/x", "ENV=/x",
		"KOGEN_NODE=/caller/node", "LC_ALL=C", "LANG=C", "GOPATH=/fixture/gopath"), p.Root)
	before := slices.Clone(s.Env)
	pr := Probe{Root: p.Root, Tools: Tools{Node: "/n/node"},
		Command: `env; echo "HOME-LIST:"; ls -A "$HOME"; echo "HOME-IS:$HOME"; ls -A "$HOME/.kogen" 2>&1; echo "HOME-DIR:$(cd "$HOME" && pwd -P)"`}
	got, err := pr.Run(context.Background(), s)
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{"STUDIO_TOKEN", "studio-secret", "OPENAI_API_KEY", "openai-secret", "UNRELATED_SECRET", "unrelated-secret",
		"KOGEN_CREDENTIALS_DIR", store, "synthetic-saved-login", "chatgpt.json", "NODE_OPTIONS", "BASH_ENV", "ENV=/x", callerHome, "/caller/node"} {
		if strings.Contains(got.Output, secret) {
			t.Errorf("probe output shows %q:\n%s", secret, got.Output)
		}
	}
	for _, want := range []string{"KOGEN_NODE=/n/node\n", "LC_ALL=C\n", "LANG=C\n", "GOPATH=/fixture/gopath\n", "PATH=", "HOME-LIST:\nHOME-IS:" + tmp + "/kogen-probe-home-"} {
		if !strings.Contains(got.Output, want) {
			t.Errorf("probe output lacks %q:\n%s", want, got.Output)
		}
	}
	eqSlice(t, "caller environment", s.Env, before)
	if !fileExists(filepath.Join(store, "chatgpt.json")) {
		t.Fatal("the caller's credential store changed")
	}
	requireNoLeftovers(t, tmp)
}

// The private home is removed when the probe is refused or interrupted too.
func TestShapeProbeMinimalEnvironmentHomeIsRemovedOnEveryReturn(t *testing.T) {
	tmp := isolateTmp(t)
	p := newProj(t)
	s, _ := p.session()
	if _, err := (Probe{Root: p.Root, Command: "true", Files: []ProbeFile{{Path: "../a"}}}).Run(context.Background(), s); err == nil {
		t.Fatal("want a refusal")
	}
	requireNoLeftovers(t, tmp)
	go func() {
		for i := 0; i < 400; i++ {
			if len(leftovers(t, tmp, "kogen-probe-home-")) > 0 {
				time.Sleep(300 * time.Millisecond)
				s.Interrupt("SIGTERM")
				return
			}
			time.Sleep(25 * time.Millisecond)
		}
	}()
	_, err := (Probe{Root: p.Root, Command: "sleep 30"}).Run(context.Background(), s)
	var intr *sys.Interrupted
	if !errors.As(err, &intr) || intr.Signal != "SIGTERM" {
		t.Fatalf("err = %v, want the caller's interrupt", err)
	}
	requireNoLeftovers(t, tmp)
}

// A caller already interrupted must not launch even a quick probe command.
func TestProbeDoesNotStartAfterCallerInterrupt(t *testing.T) {
	tmp := isolateTmp(t)
	p := newProj(t)
	s, _ := p.session()
	s.Interrupt("SIGTERM")
	marker := filepath.Join(tmp, "started")
	_, err := (Probe{Root: p.Root, Command: "touch '" + marker + "'"}).Run(context.Background(), s)
	var intr *sys.Interrupted
	if !errors.As(err, &intr) || intr.Signal != "SIGTERM" {
		t.Fatalf("err = %v", err)
	}
	if fileExists(marker) {
		t.Fatal("probe started after interrupt")
	}
	requireNoLeftovers(t, tmp)
}

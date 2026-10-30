package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
	"unicode/utf8"

	"kogen/project"
)

// The tests below drive the real built kogen binary on a temporary Git project through
// `kogen intent approve`. Commands in the fixtures are owned shell processes that sleep or
// block: nothing generates CPU load, installs packages or compiles.

const approveSlug = "goose-labels-go"

const approveFeatureText = "Feature: Goose labels\n  Scenario: Labels are printed\n    Then the labels are printed\n"

const approveIntentText = "# Goose labels\n\nSlug: goose-labels-go\nModel: not applicable — nothing to model\nAcceptance:\n" +
	"- .kogen/intents/goose-labels-go/acceptance.feature\n- features/steps/goose_steps.js\n\nLabels.\n\n" +
	"## Decisions\n- Labels decision. (source: request)\n\n## Tests\n- none: fixture\n\n## Feasibility\n- none\n"

type approveMessage = map[string]any

// approveGreenReport is a valid Cucumber Messages report accounting the one scenario of
// approveFeatureText as passed.
func approveGreenReport(t *testing.T) string {
	t.Helper()
	scenarios, err := project.ParseGherkin(approveFeatureText)
	if err != nil {
		t.Fatal(err)
	}
	uri := project.FeaturePath(approveSlug)
	var children, astSteps, pickleSteps, testSteps, finished []any
	var events []approveMessage
	sc := scenarios[0]
	for j, st := range sc.Steps {
		astSteps = append(astSteps, approveMessage{"id": fmt.Sprintf("ast-step-%d", j+1), "location": approveMessage{"line": st.Line}, "keyword": st.Keyword})
		pickleSteps = append(pickleSteps, approveMessage{"id": fmt.Sprintf("p-%d", j+1), "astNodeIds": []any{fmt.Sprintf("ast-step-%d", j+1)}, "text": st.Text})
		testSteps = append(testSteps, approveMessage{"id": fmt.Sprintf("t-%d", j+1), "pickleStepId": fmt.Sprintf("p-%d", j+1)})
		finished = append(finished, approveMessage{"testStepFinished": approveMessage{"testCaseStartedId": "s-1", "testStepId": fmt.Sprintf("t-%d", j+1), "testStepResult": approveMessage{"status": "PASSED"}}})
	}
	children = append(children, approveMessage{"scenario": approveMessage{"id": "ast-sc-1", "location": approveMessage{"line": sc.Line}, "steps": astSteps, "examples": []any{}}})
	events = append(events,
		approveMessage{"gherkinDocument": approveMessage{"uri": uri, "feature": approveMessage{"children": children}}},
		approveMessage{"pickle": approveMessage{"id": "pk-1", "uri": uri, "name": sc.Name, "astNodeIds": []any{"ast-sc-1"}, "steps": pickleSteps}},
		approveMessage{"testCase": approveMessage{"id": "c-1", "pickleId": "pk-1", "testSteps": testSteps}},
		approveMessage{"testCaseStarted": approveMessage{"id": "s-1", "testCaseId": "c-1"}})
	for _, f := range finished {
		events = append(events, f.(approveMessage))
	}
	events = append(events, approveMessage{"testCaseFinished": approveMessage{"testCaseStartedId": "s-1", "willBeRetried": false}})
	var b strings.Builder
	for _, e := range events {
		line, err := json.Marshal(e)
		if err != nil {
			t.Fatal(err)
		}
		b.Write(line)
		b.WriteByte('\n')
	}
	return b.String()
}

// approveCLI is one temporary project with a built kogen binary and an isolated home.
type approveCLI struct {
	t    *testing.T
	bin  string
	Root string
	Aux  string // outside the repository: counters, pid files, the prepared report
	Home string
	Env  []string
}

// approveSpec describes a project: the setup commands, the acceptance command and the files
// they run. Scripts may name the auxiliary folder as @AUX@.
type approveSpec struct {
	Setup   []string
	Accept  string
	Scripts map[string]string
	Env     []string // added to the kogen environment
}

func buildApproveCLI(t *testing.T, spec approveSpec) *approveCLI {
	t.Helper()
	prefix := t.TempDir()
	bin := filepath.Join(prefix, "lib", "kogen", "bin", "kogen")
	if err := os.MkdirAll(filepath.Dir(bin), 0o755); err != nil {
		t.Fatal(err)
	}
	if out, err := exec.Command("go", "build", "-o", bin, ".").CombinedOutput(); err != nil {
		t.Fatalf("go build: %v\n%s", err, out)
	}
	c := &approveCLI{t: t, bin: bin, Root: t.TempDir(), Aux: t.TempDir(), Home: t.TempDir()}
	for _, kv := range os.Environ() {
		if !strings.HasPrefix(kv, "GIT_") && !strings.HasPrefix(kv, "HOME=") {
			c.Env = append(c.Env, kv)
		}
	}
	c.Env = append(c.Env, "HOME="+c.Home, "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1", "GIT_TERMINAL_PROMPT=0")
	c.Env = append(c.Env, spec.Env...)

	if err := os.WriteFile(filepath.Join(c.Aux, "green.ndjson"), []byte(approveGreenReport(t)), 0o644); err != nil {
		t.Fatal(err)
	}
	c.git("init", "-q")
	c.git("config", "user.name", "Fixture")
	c.git("config", "user.email", "fixture@example.invalid")
	c.git("config", "core.hooksPath", t.TempDir())
	c.git("config", "commit.gpgsign", "false")
	c.write(".gitignore", ".kogen/local/\nnode_modules/\n")
	c.write("go.mod", "module goose-labels-go\n\ngo 1.27\n")
	c.write("main.go", "package main\n\nfunc main() {}\n")
	c.write("package.json", "{\"name\":\"goose-labels-go\",\"private\":true}\n")
	// vendor/ is tracked data; node_modules is ignored and stays out of the candidate.
	for i := 0; i < 40; i++ {
		c.write(fmt.Sprintf("vendor/example.invalid/pkg%02d/data.go", i), fmt.Sprintf("package pkg%02d\n\n// %s\n", i, strings.Repeat("vendored data ", 200)))
		c.write(fmt.Sprintf("node_modules/dep%02d/index.js", i), "module.exports = 1\n")
	}
	var yaml strings.Builder
	yaml.WriteString("version: 1\ncommands:\n")
	if len(spec.Setup) > 0 {
		yaml.WriteString("  setup:\n")
		for _, cmd := range spec.Setup {
			yaml.WriteString("    - " + yamlQuote(cmd) + "\n")
		}
	}
	yaml.WriteString("  acceptance:\n    run: " + yamlQuote(spec.Accept) + "\n")
	c.write(".kogen/project.yaml", yaml.String())
	c.write(project.IntentMDPath(approveSlug), approveIntentText)
	c.write(project.FeaturePath(approveSlug), approveFeatureText)
	c.write("features/steps/goose_steps.js", "// steps\n")
	for name, body := range spec.Scripts {
		c.write(name, strings.ReplaceAll(body, "@AUX@", c.Aux))
		os.Chmod(filepath.Join(c.Root, name), 0o755)
	}
	c.git("add", "-A")
	c.git("commit", "-qm", "fixture project")
	t.Cleanup(c.killOwned)
	return c
}

func yamlQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", "''") + "'" }

func (c *approveCLI) git(args ...string) string {
	c.t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = c.Root
	cmd.Env = c.Env
	out, err := cmd.CombinedOutput()
	if err != nil {
		c.t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
	}
	return string(out)
}

func (c *approveCLI) write(rel, content string) {
	c.t.Helper()
	path := filepath.Join(c.Root, rel)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		c.t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		c.t.Fatal(err)
	}
}

// gitState is what the card and the refusals must leave alone: HEAD, the real index file and
// the staged entries.
func (c *approveCLI) gitState() string {
	c.t.Helper()
	index, err := os.ReadFile(filepath.Join(c.Root, ".git", "index"))
	if err != nil {
		c.t.Fatal(err)
	}
	return strings.TrimSpace(c.git("rev-parse", "HEAD")) + "\n" + c.git("ls-files", "-s") + fmt.Sprintf("%x", sha256.Sum256(index))
}

type approveRun struct {
	Exit            int
	Stdout, Stderr  string
	Elapsed         time.Duration
	TimedOutByTests bool
}

// run runs `kogen <args> --project <root>`, never waiting more than limit, and kills the
// whole process group of the invocation if it does.
func (c *approveCLI) run(limit time.Duration, args ...string) approveRun {
	c.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), limit)
	defer cancel()
	cmd := exec.CommandContext(ctx, c.bin, append(args, "--project", c.Root)...)
	cmd.Dir = c.Root
	cmd.Env = c.Env
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = 5 * time.Second
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	began := time.Now()
	err := cmd.Run()
	res := approveRun{Stdout: stdout.String(), Stderr: stderr.String(), Elapsed: time.Since(began), TimedOutByTests: ctx.Err() != nil}
	var ee *exec.ExitError
	switch {
	case err == nil:
	case errors.As(err, &ee):
		res.Exit = ee.ExitCode()
	default:
		c.t.Fatalf("kogen did not run: %v", err)
	}
	if res.TimedOutByTests {
		c.t.Fatalf("kogen %v did not finish within %s\nstdout:\n%s\nstderr:\n%s", args, limit, res.Stdout, res.Stderr)
	}
	return res
}

func (c *approveCLI) card(limit time.Duration) approveRun {
	c.t.Helper()
	return c.run(limit, "intent", "approve", approveSlug)
}

// killOwned stops whatever the fixtures left running, by the pids they wrote.
func (c *approveCLI) killOwned() {
	files, _ := filepath.Glob(filepath.Join(c.Aux, "*.pid"))
	for _, f := range files {
		if b, err := os.ReadFile(f); err == nil {
			if pid, err := strconv.Atoi(strings.TrimSpace(string(b))); err == nil && pid > 1 {
				syscall.Kill(pid, syscall.SIGKILL)
			}
		}
	}
}

// count is how many times a fixture command ran: its script appends a line to Aux/<name>.
func (c *approveCLI) count(name string) int {
	b, err := os.ReadFile(filepath.Join(c.Aux, name))
	if err != nil {
		return 0
	}
	return strings.Count(string(b), "\n")
}

func (c *approveCLI) approvalPath() string {
	return filepath.Join(c.Root, ".kogen/local/approvals", approveSlug+".json")
}

func (c *approveCLI) exists(rel string) bool {
	_, err := os.Lstat(filepath.Join(c.Root, rel))
	return err == nil
}

var fullHashRe = regexp.MustCompile(`\b[0-9a-f]{64}\b`)

// ---- retained evidence ----

type evidenceStep struct {
	Name       string `json:"name"`
	Kind       string `json:"kind"`
	Command    string `json:"command"`
	Status     string `json:"status"`
	Exit       *int   `json:"exit"`
	TimedOut   *bool  `json:"timed_out"`
	StartMS    int64  `json:"start_ms"`
	DurationMS *int64 `json:"duration_ms"`
	Output     string `json:"output"`
}

type evidenceRecord struct {
	Version   int            `json:"version"`
	Kind      string         `json:"kind"`
	Outcome   string         `json:"outcome"`
	Slug      string         `json:"slug"`
	ElapsedMS int64          `json:"elapsed_ms"`
	Steps     []evidenceStep `json:"steps"`
	NotRun    []string       `json:"not_run"`
	Failure   struct {
		Class    string   `json:"class"`
		Reason   string   `json:"reason"`
		Step     string   `json:"step"`
		TimedOut bool     `json:"timed_out"`
		Lines    []string `json:"lines"`
	} `json:"failure"`
	Raw []byte `json:"-"`
}

var evidenceLineRe = regexp.MustCompile(`(?m)^\s*Evidence: (\S.*)$`)

// readEvidence reads the attempt evidence the refusal names and checks its custody: inside
// .kogen/local/readiness/attempts, in its own 0700 folder, a 0600 file.
func (c *approveCLI) readEvidence(stdout string) (string, evidenceRecord) {
	c.t.Helper()
	m := evidenceLineRe.FindStringSubmatch(stdout)
	if m == nil {
		c.t.Fatalf("the refusal names no evidence file:\n%s", stdout)
	}
	path := strings.TrimSpace(m[1])
	attempts := filepath.Join(c.Root, ".kogen/local/readiness/attempts")
	if !strings.HasPrefix(path, attempts+string(filepath.Separator)) || filepath.Base(path) != "attempt.json" {
		c.t.Fatalf("evidence path %q is not an attempt file below %s", path, attempts)
	}
	for _, p := range []string{path, filepath.Dir(path)} {
		st, err := os.Stat(p)
		if err != nil {
			c.t.Fatal(err)
		}
		want := os.FileMode(0o600)
		if st.IsDir() {
			want = 0o700
		}
		if st.Mode().Perm() != want {
			c.t.Errorf("%s has mode %v, want %v", p, st.Mode().Perm(), want)
		}
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		c.t.Fatal(err)
	}
	var rec evidenceRecord
	if err := json.Unmarshal(raw, &rec); err != nil {
		c.t.Fatalf("evidence is not JSON: %v", err)
	}
	rec.Raw = raw
	return path, rec
}

func (r evidenceRecord) step(name string) *evidenceStep {
	for i := range r.Steps {
		if r.Steps[i].Name == name {
			return &r.Steps[i]
		}
	}
	return nil
}

func (r evidenceRecord) names() []string {
	var out []string
	for _, s := range r.Steps {
		out = append(out, s.Name)
	}
	return out
}

func requireContains(t *testing.T, what, text string, wants ...string) {
	t.Helper()
	for _, w := range wants {
		if !strings.Contains(text, w) {
			t.Errorf("%s lacks %q:\n%s", what, w, clip(text))
		}
	}
}

func requireLacks(t *testing.T, what, text string, unwanted ...string) {
	t.Helper()
	for _, w := range unwanted {
		if strings.Contains(text, w) {
			t.Errorf("%s contains %q:\n%s", what, w, clip(text))
		}
	}
}

func clip(s string) string {
	if len(s) > 6000 {
		return s[:3000] + "\n[... clipped by the test ...]\n" + s[len(s)-3000:]
	}
	return s
}

func pidAlive(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

func readPID(t *testing.T, path string) int {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("the fixture wrote no pid: %v", err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(b)))
	if err != nil {
		t.Fatal(err)
	}
	return pid
}

// ---- tests ----

// Setup and the acceptance wrapper each take 65 seconds and succeed: together they exceed the
// 120-second step bound, neither alone does, so the card is shown and the exact hash approves.
func TestApproveDeadlineSplitCLI(t *testing.T) {
	t.Parallel()
	c := buildApproveCLI(t, approveSpec{
		Setup:  []string{"sh ./setup.sh"},
		Accept: "sh ./accept.sh",
		Scripts: map[string]string{
			"setup.sh":  "#!/bin/sh\necho run >> '@AUX@/setup-runs'\necho 'npm ci (an owned wait, nothing is installed)'\nsleep 65\n",
			"accept.sh": "#!/bin/sh\necho run >> '@AUX@/accept-runs'\necho 'go build ./... (an owned wait, nothing is compiled)'\nsleep 65\ncp '@AUX@/green.ndjson' \"$KOGEN_ACCEPTANCE_REPORT\"\n",
		},
	})
	before := c.gitState()

	card := c.card(5 * time.Minute)
	if card.Exit != 5 {
		t.Fatalf("card exit %d, want 5\n%s\n%s", card.Exit, card.Stdout, card.Stderr)
	}
	if card.Elapsed < 120*time.Second {
		t.Fatalf("the card took %s: the fixture must exceed the 120-second step bound overall", card.Elapsed)
	}
	requireLacks(t, "the card", card.Stdout+card.Stderr, "timed out", "step_timeout", "git add")
	hash := fullHashRe.FindString(card.Stdout)
	if hash == "" {
		t.Fatalf("the card shows no full hash:\n%s", card.Stdout)
	}
	requireContains(t, "the card", card.Stdout, "kogen intent approve "+approveSlug+" "+hash)
	if c.exists(".kogen/local/approvals/" + approveSlug + ".json") {
		t.Fatal("the card approved")
	}
	if c.count("setup-runs") != 1 || c.count("accept-runs") != 1 {
		t.Fatalf("setup ran %d times and the wrapper %d times, want once each", c.count("setup-runs"), c.count("accept-runs"))
	}
	if after := c.gitState(); after != before {
		t.Fatalf("the card changed HEAD or the index:\n%s\n---\n%s", before, after)
	}

	approved := c.run(time.Minute, "intent", "approve", approveSlug, hash)
	if approved.Exit != 0 {
		t.Fatalf("approval exit %d\n%s\n%s", approved.Exit, approved.Stdout, approved.Stderr)
	}
	requireContains(t, "the approval", approved.Stdout, "approved "+approveSlug+" "+hash[:8])
	marker, err := os.ReadFile(c.approvalPath())
	if err != nil {
		t.Fatal(err)
	}
	requireContains(t, "the approval marker", string(marker), hash)
	if approved.Elapsed > 30*time.Second {
		t.Errorf("approval took %s: unchanged readiness must be reused, not run again", approved.Elapsed)
	}
	if c.count("setup-runs") != 1 || c.count("accept-runs") != 1 {
		t.Errorf("approval ran setup %d and the wrapper %d times in all, want once each: no retry and normal reuse", c.count("setup-runs"), c.count("accept-runs"))
	}
	if after := c.gitState(); after != before {
		t.Fatalf("approval changed HEAD or the index:\n%s\n---\n%s", before, after)
	}
	if entries, _ := os.ReadDir(filepath.Join(c.Root, ".kogen/local/readiness/attempts")); len(entries) != 0 {
		t.Errorf("a successful approval retained %d refused attempts", len(entries))
	}
}

// A setup step that blocks is stopped by its own 120-second bound and refused as a step timeout,
// naming the steps that ran before it; nothing else runs, nothing is approved and nothing the
// step started survives.
func TestApproveDeadlineHungCLI(t *testing.T) {
	t.Parallel()
	c := buildApproveCLI(t, approveSpec{
		Setup:  []string{"sh ./setup.sh"},
		Accept: "sh ./accept.sh",
		Scripts: map[string]string{
			"setup.sh": "#!/bin/sh\necho run >> '@AUX@/setup-runs'\necho $$ > '@AUX@/setup.pid'\n" +
				"echo 'hung-setup-stderr-diagnostic' >&2\nsleep 600 &\necho $! > '@AUX@/child.pid'\nwait\n",
			"accept.sh": "#!/bin/sh\necho run >> '@AUX@/accept-runs'\ncp '@AUX@/green.ndjson' \"$KOGEN_ACCEPTANCE_REPORT\"\n",
		},
	})
	before := c.gitState()

	res := c.card(4 * time.Minute)
	if res.Exit != 3 {
		t.Fatalf("exit %d, want the refusal exit 3\n%s\n%s", res.Exit, res.Stdout, res.Stderr)
	}
	if res.Elapsed < 115*time.Second || res.Elapsed > 200*time.Second {
		t.Errorf("the refusal took %s: the unchanged 120-second step bound plus teardown", res.Elapsed)
	}
	requireContains(t, "the refusal", res.Stdout, "environment/step_timeout", "setup-1", "timed out", "hung-setup-stderr-diagnostic", "snapshot: passed in", "materialize: passed in", "Not run: acceptance")
	requireLacks(t, "the refusal", res.Stdout, "git add", "status 143", "setup_failed")
	if !regexp.MustCompile(`setup-1: timed out after \d+\.\ds`).MatchString(res.Stdout) {
		t.Errorf("the refusal gives no numeric elapsed time for setup-1:\n%s", res.Stdout)
	}
	requireContains(t, "the refusal", res.Stdout, "names no cause")

	_, rec := c.readEvidence(res.Stdout)
	setup := rec.step("setup-1")
	if setup == nil || setup.TimedOut == nil || !*setup.TimedOut || setup.Status != "timed_out" || setup.DurationMS == nil ||
		*setup.DurationMS < 119000 || *setup.DurationMS > 150000 {
		t.Fatalf("setup-1 evidence = %+v", setup)
	}
	if rec.Failure.Step != "setup-1" || !rec.Failure.TimedOut || rec.Failure.Reason != "step_timeout" {
		t.Errorf("failure = %+v", rec.Failure)
	}
	if got := rec.names(); len(got) != 3 || got[0] != "snapshot" || got[1] != "materialize" || got[2] != "setup-1" {
		t.Errorf("steps = %v, want snapshot, materialize, setup-1", got)
	}
	if len(rec.NotRun) != 1 || rec.NotRun[0] != "acceptance" {
		t.Errorf("not_run = %v", rec.NotRun)
	}

	if c.count("setup-runs") != 1 {
		t.Errorf("the blocked setup ran %d times, want once and no retry", c.count("setup-runs"))
	}
	if c.count("accept-runs") != 0 {
		t.Errorf("acceptance ran after the timeout")
	}
	if c.exists(".kogen/local/approvals/" + approveSlug + ".json") {
		t.Error("a timed-out approval was approved")
	}
	if c.exists(".kogen/local/readiness/" + approveSlug + ".json") {
		t.Error("a timeout became ready evidence")
	}
	if after := c.gitState(); after != before {
		t.Errorf("the refusal changed HEAD or the index")
	}
	for _, f := range []string{"setup.pid", "child.pid"} {
		pid := readPID(t, filepath.Join(c.Aux, f))
		deadline := time.Now().Add(10 * time.Second)
		for pidAlive(pid) && time.Now().Before(deadline) {
			time.Sleep(50 * time.Millisecond)
		}
		if pidAlive(pid) {
			t.Errorf("%s: process %d still runs after the refusal", f, pid)
		}
	}
}

// A refused command's own stdout and stderr reach the refusal and the retained evidence: an
// acceptance exit 134 without a report, a failing setup and a failing check inside the wrapper.
func TestApproveFailureOutputCLI(t *testing.T) {
	const out, errm = "command-stdout-diagnostic", "command-stderr-diagnostic"
	emit := func(prefix string) string {
		return prefix + "echo '" + out + "'\necho '" + errm + "' >&2\n"
	}
	for _, tc := range []struct {
		name   string
		spec   approveSpec
		exit   int
		step   string
		stepOK []string // steps that passed before it
		want   []string // in the refusal
		notRun []string
	}{
		{
			name: "acceptance exit 134 without a report",
			spec: approveSpec{Setup: []string{"sh ./setup.sh"}, Accept: "sh ./accept.sh", Scripts: map[string]string{
				"setup.sh":  "#!/bin/sh\necho run >> '@AUX@/setup-runs'\n",
				"accept.sh": emit("#!/bin/sh\necho run >> '@AUX@/accept-runs'\necho 'kogen: running setup-1: fixture'\n") + "exit 134\n",
			}},
			exit: 1, step: "acceptance", stepOK: []string{"setup-1"},
			want: []string{"report_missing: the acceptance command exited 134; its output:", "kogen: running setup-1: fixture"},
		},
		{
			name: "setup exit 23",
			spec: approveSpec{Setup: []string{"sh ./setup.sh"}, Accept: "sh ./accept.sh", Scripts: map[string]string{
				"setup.sh":  emit("#!/bin/sh\necho run >> '@AUX@/setup-runs'\n") + "exit 23\n",
				"accept.sh": "#!/bin/sh\necho run >> '@AUX@/accept-runs'\n",
			}},
			exit: 3, step: "setup-1",
			want:   []string{"environment/setup_failed", "Setup setup-1 failed (status=23)."},
			notRun: []string{"acceptance"},
		},
		{
			name: "acceptance wrapper check exit 17",
			spec: approveSpec{Setup: []string{"sh ./setup.sh"}, Accept: "sh ./accept.sh", Scripts: map[string]string{
				"setup.sh": "#!/bin/sh\necho run >> '@AUX@/setup-runs'\n",
				"accept.sh": emit("#!/bin/sh\necho run >> '@AUX@/accept-runs'\necho 'check go build ./... failed'\n") +
					"cp '@AUX@/green.ndjson' \"$KOGEN_ACCEPTANCE_REPORT\"\nexit 17\n",
			}},
			exit: 1, step: "acceptance", stepOK: []string{"setup-1"},
			want: []string{"exit 17 with all scenarios passed; its output:", "check go build ./... failed"},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := buildApproveCLI(t, tc.spec)
			before := c.gitState()
			res := c.card(time.Minute)
			if res.Exit != tc.exit {
				t.Fatalf("exit %d, want %d\n%s\n%s", res.Exit, tc.exit, res.Stdout, res.Stderr)
			}
			requireContains(t, "the refusal", res.Stdout, append([]string{out, errm}, tc.want...)...)
			_, rec := c.readEvidence(res.Stdout)
			failing := rec.step(tc.step)
			if failing == nil || failing.Exit == nil || failing.Status != "failed" || rec.Failure.Step != tc.step {
				t.Fatalf("failing step %q = %+v, failure %+v", tc.step, failing, rec.Failure)
			}
			wantExit := map[string]int{"acceptance exit 134 without a report": 134, "setup exit 23": 23, "acceptance wrapper check exit 17": 17}[tc.name]
			if *failing.Exit != wantExit {
				t.Errorf("recorded exit %d, want %d", *failing.Exit, wantExit)
			}
			requireContains(t, "the retained output of "+tc.step, failing.Output, out, errm)
			for _, w := range tc.want[len(tc.want)-1:] {
				requireContains(t, "the retained evidence", string(rec.Raw), strings.ReplaceAll(w, "\n", `\n`))
			}
			for _, name := range tc.stepOK {
				if s := rec.step(name); s == nil || s.Status != "passed" {
					t.Errorf("step %s = %+v, want passed", name, s)
				}
			}
			if c.count("setup-runs") != 1 {
				t.Errorf("setup ran %d times, want once", c.count("setup-runs"))
			}
			wantAccept := 0
			if tc.step == "acceptance" {
				wantAccept = 1
			}
			if c.count("accept-runs") != wantAccept {
				t.Errorf("acceptance ran %d times, want %d: no rerun and no later work", c.count("accept-runs"), wantAccept)
			}
			if c.exists(".kogen/local/approvals/"+approveSlug+".json") || c.exists(".kogen/local/readiness/"+approveSlug+".json") {
				t.Error("a refused check approved or became readiness evidence")
			}
			if c.gitState() != before {
				t.Error("the refusal changed HEAD or the index")
			}
			if len(tc.notRun) > 0 && fmt.Sprint(rec.NotRun) != fmt.Sprint(tc.notRun) {
				t.Errorf("not_run = %v, want %v", rec.NotRun, tc.notRun)
			}
		})
	}
}

var displayedStepRe = regexp.MustCompile(`(?m)^\s+(\S+): (?:passed in|failed with exit \d+ after) ([0-9.]+)s$`)

// The evidence of a refusal records the steps that ran, in order, with truthful durations and
// terminal statuses; steps never reached are only named. It is not readiness evidence and
// neither it nor a later invocation disturbs other evidence.
func TestApproveFailureEvidenceCLI(t *testing.T) {
	setupOK := "#!/bin/sh\necho run >> '@AUX@/setup-runs'\nsleep 1\n"
	for _, tc := range []struct {
		name     string
		scripts  map[string]string
		steps    []string
		failing  string
		notRun   []string
		failExit int
	}{
		{
			name: "setup completes and acceptance fails",
			scripts: map[string]string{
				"setup.sh":  setupOK,
				"accept.sh": "#!/bin/sh\necho run >> '@AUX@/accept-runs'\nsleep 1\necho acceptance-diagnostic >&2\nexit 134\n",
			},
			steps: []string{"snapshot", "materialize", "setup-1", "acceptance"}, failing: "acceptance", failExit: 134,
		},
		{
			name: "setup fails and acceptance is not run",
			scripts: map[string]string{
				"setup.sh":  "#!/bin/sh\necho run >> '@AUX@/setup-runs'\nsleep 1\necho setup-diagnostic >&2\nexit 23\n",
				"accept.sh": "#!/bin/sh\necho run >> '@AUX@/accept-runs'\n",
			},
			steps: []string{"snapshot", "materialize", "setup-1"}, failing: "setup-1", notRun: []string{"acceptance"}, failExit: 23,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := buildApproveCLI(t, approveSpec{Setup: []string{"sh ./setup.sh"}, Accept: "sh ./accept.sh", Scripts: tc.scripts})
			// Evidence of an unrelated attempt and another Intent's readiness stay as they are.
			unrelated := filepath.Join(c.Root, ".kogen/local/readiness/attempts/unrelated-1/attempt.json")
			other := filepath.Join(c.Root, ".kogen/local/readiness/other-intent.json")
			for path, body := range map[string]string{unrelated: "{\"unrelated\":true}\n", other: "{\"version\":3}\n"} {
				if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			before := c.gitState()

			first := c.card(time.Minute)
			if first.Exit == 0 || first.Exit == 5 {
				t.Fatalf("exit %d, want a refusal\n%s", first.Exit, first.Stdout)
			}
			path, rec := c.readEvidence(first.Stdout)
			if rec.Version != 1 || rec.Kind != "approval_attempt" || rec.Outcome != "refused" || rec.Slug != approveSlug {
				t.Errorf("evidence identity = version %d kind %q outcome %q slug %q", rec.Version, rec.Kind, rec.Outcome, rec.Slug)
			}
			if got := rec.names(); fmt.Sprint(got) != fmt.Sprint(tc.steps) {
				t.Fatalf("executed steps = %v, want %v in order", got, tc.steps)
			}
			var previousEnd, total int64
			for _, s := range rec.Steps {
				if s.DurationMS == nil || *s.DurationMS < 0 || s.StartMS < previousEnd-1 || s.TimedOut == nil || s.Status == "" || s.Kind == "" {
					t.Errorf("step %+v: needs a nonnegative duration, a start no earlier than the previous end, a timeout flag, a status and a kind", s)
					continue
				}
				previousEnd = s.StartMS + *s.DurationMS
				total += *s.DurationMS
				if s.Name != tc.failing && s.Status != "passed" {
					t.Errorf("step %s status %q, want passed", s.Name, s.Status)
				}
				if *s.TimedOut {
					t.Errorf("step %s is marked timed out", s.Name)
				}
			}
			if total > rec.ElapsedMS+50 {
				t.Errorf("steps took %dms in all, more than the attempt's %dms", total, rec.ElapsedMS)
			}
			if sleepy := rec.step("setup-1"); sleepy == nil || *sleepy.DurationMS < 900 {
				t.Errorf("setup-1 = %+v: it slept one second", sleepy)
			}
			failing := rec.step(tc.failing)
			if failing == nil || failing.Status != "failed" || failing.Exit == nil || *failing.Exit != tc.failExit || rec.Failure.Step != tc.failing || rec.Failure.TimedOut {
				t.Errorf("failing step = %+v, failure %+v", failing, rec.Failure)
			}
			if fmt.Sprint(rec.NotRun) != fmt.Sprint(append([]string{}, tc.notRun...)) && !(len(rec.NotRun) == 0 && len(tc.notRun) == 0) {
				t.Errorf("not_run = %v, want %v", rec.NotRun, tc.notRun)
			}
			for _, name := range tc.notRun {
				if rec.step(name) != nil || strings.Contains(first.Stdout, name+": passed") || strings.Contains(first.Stdout, name+": failed") {
					t.Errorf("unexecuted step %s was given a duration or status", name)
				}
			}
			// The displayed durations are the retained ones, within their rounding.
			displayed := displayedStepRe.FindAllStringSubmatch(first.Stdout, -1)
			if len(displayed) != len(rec.Steps) {
				t.Fatalf("the refusal displays %d steps, the evidence holds %d:\n%s", len(displayed), len(rec.Steps), first.Stdout)
			}
			for i, d := range displayed {
				seconds, _ := strconv.ParseFloat(d[2], 64)
				if d[1] != rec.Steps[i].Name || seconds < float64(*rec.Steps[i].DurationMS)/1000-0.06 || seconds > float64(*rec.Steps[i].DurationMS)/1000+0.06 {
					t.Errorf("displayed %s for %.1fs, retained %s for %dms", d[1], seconds, rec.Steps[i].Name, *rec.Steps[i].DurationMS)
				}
			}
			// Refused evidence is not ready evidence: no readiness record exists, so a fresh
			// invocation runs the normal checks again and refuses again, in a new attempt folder.
			if c.exists(".kogen/local/readiness/" + approveSlug + ".json") {
				t.Fatal("a refusal left a readiness record")
			}
			if c.count("setup-runs") != 1 {
				t.Fatalf("setup ran %d times in the first invocation", c.count("setup-runs"))
			}
			second := c.card(time.Minute)
			if second.Exit != first.Exit {
				t.Errorf("second exit %d, first %d", second.Exit, first.Exit)
			}
			if c.count("setup-runs") != 2 {
				t.Errorf("the fresh invocation ran setup %d times in all, want the normal checks again (2)", c.count("setup-runs"))
			}
			path2, _ := c.readEvidence(second.Stdout)
			if path2 == path {
				t.Error("a second refusal reused the first attempt's folder")
			}
			if b, err := os.ReadFile(path); err != nil || !bytes.Equal(b, rec.Raw) {
				t.Error("a later attempt changed the first attempt's evidence")
			}
			for p, body := range map[string]string{unrelated: "{\"unrelated\":true}\n", other: "{\"version\":3}\n"} {
				if b, err := os.ReadFile(p); err != nil || string(b) != body {
					t.Errorf("unrelated evidence %s changed: %v %q", p, err, b)
				}
			}
			if c.gitState() != before {
				t.Error("a refusal changed HEAD or the index")
			}
			if c.exists(".kogen/local/approvals/" + approveSlug + ".json") {
				t.Error("a refusal approved")
			}
		})
	}
}

// Secrets are masked before the diagnostic is cut to its bounds, so no bound can split one;
// the existing 16 KiB display, 1 MiB record and line policy remain and keep both ends.
func TestApproveFailureBoundsCLI(t *testing.T) {
	const (
		envSecret    = "ENVSECRET-9f1c27ab55d0"
		credSecret   = "CREDSECRET-4be2c9017d3a"
		bearerSecret = "bearerSecretValue0123456789"
		assignSecret = "assignSecretValue-77aa"
		argSecret    = "argSecretValue-5c5c5c"
		head, tail   = "head-diagnostic-marker", "tail-diagnostic-marker"
	)
	secrets := []string{envSecret, credSecret, bearerSecret, assignSecret, argSecret}
	// The first secret begins 6 bytes before the 4096-byte head the display keeps, so the cut
	// would fall inside it. Padding is 2-byte UTF-8 letters.
	prefix := head + "\n"
	padding := 4090 - len(prefix)
	filler := strings.Repeat("é", padding/2) + strings.Repeat("a", padding%2)
	line := prefix + filler + envSecret + strings.Repeat("é", 20000) + credSecret + "\n"
	var script strings.Builder
	script.WriteString("#!/bin/sh\necho run >> '@AUX@/accept-runs'\n")
	script.WriteString("printf '%s' '" + line + "'\n")
	script.WriteString("echo \"stdout \"$FAKE_SERVICE_TOKEN\n")
	script.WriteString("echo 'Authorization: Bearer " + bearerSecret + "' >&2\n")
	script.WriteString("echo 'api_key=" + assignSecret + "' >&2\n")
	script.WriteString("i=0; while [ $i -lt 400 ]; do echo \"filler line $i with harmless words\"; i=$((i+1)); done\n")
	script.WriteString("echo \"" + tail + "\" >&2\nexit 134\n")
	c := buildApproveCLI(t, approveSpec{
		Setup:  []string{"sh ./setup.sh --token=" + argSecret},
		Accept: "sh ./accept.sh",
		Env:    []string{"FAKE_SERVICE_TOKEN=" + envSecret},
		Scripts: map[string]string{
			"setup.sh":  "#!/bin/sh\necho run >> '@AUX@/setup-runs'\n",
			"accept.sh": script.String(),
		},
	})
	credDir := filepath.Join(c.Home, ".kogen", "credentials")
	if err := os.MkdirAll(credDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(credDir, "anthropic.json"), []byte(`{"provider":"anthropic","api_key":"`+credSecret+`"}`+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	res := c.card(time.Minute)
	if res.Exit != 1 {
		t.Fatalf("exit %d, want 1\n%s\n%s", res.Exit, clip(res.Stdout), clip(res.Stderr))
	}
	_, rec := c.readEvidence(res.Stdout)
	everything := res.Stdout + "\n" + res.Stderr + "\n" + string(rec.Raw)
	filepath.WalkDir(filepath.Join(c.Root, ".kogen/local"), func(path string, d os.DirEntry, err error) error {
		if err == nil && d.Type().IsRegular() {
			if b, rerr := os.ReadFile(path); rerr == nil {
				everything += "\n" + string(b)
			}
		}
		return nil
	})
	for _, s := range secrets {
		requireLacks(t, "the refusal, evidence and logs", everything, s)
	}
	requireContains(t, "the refusal", res.Stdout, head, tail, Redacted())

	// The display keeps its 16 KiB bound (plus the few fixed lines around it) and the record
	// its 1 MiB cap, and the retained output is valid UTF-8 with both ends.
	if len(res.Stdout) > 16384+2048 {
		t.Errorf("the refusal is %d bytes, more than the 16384-byte display bound and its fixed lines", len(res.Stdout))
	}
	acceptance := rec.step("acceptance")
	if acceptance == nil {
		t.Fatalf("no acceptance step in %v", rec.names())
	}
	if len(acceptance.Output) > 1<<20 || !utf8.ValidString(acceptance.Output) {
		t.Errorf("the retained output is %d bytes, valid UTF-8 %v", len(acceptance.Output), utf8.ValidString(acceptance.Output))
	}
	requireContains(t, "the retained output", acceptance.Output, head, tail, "filler line 0 ", "filler line 399 ", Redacted())
	setup := rec.step("setup-1")
	if setup == nil || strings.Contains(setup.Command, argSecret) || !strings.Contains(setup.Command, "--token="+Redacted()) {
		t.Errorf("setup-1 command = %+v: its argument secret must be masked", setup)
	}
	for _, line := range strings.Split(res.Stdout, "\n") {
		if strings.Contains(line, "filler line 3") && strings.Contains(line, "harmless words") {
			return
		}
	}
	t.Errorf("fitting nonsecret diagnostics did not survive in the refusal:\n%s", clip(res.Stdout))
}

// Redacted is the mask the product writes in place of a secret.
func Redacted() string { return "[REDACTED]" }

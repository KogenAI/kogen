// Package conformance is the executable part of Kogen's executor contract v1
// (docs/executor-contract.md §6): behavior scripts every executor must perform and the
// assertions shared by all of them. An adapter supplies a Driver that makes its backend
// (scripted fake provider, fake claude executable, ...) perform a script; Run checks the
// executor-level outcome. Build-level guarantees (no completion bypass, detection) are tested
// in package build with a fake Executor.
package conformance

import (
	"context"
	"embed"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"kogen-loop/sys"
	"kogen/executor"
)

//go:embed scripts/*.json
var scriptFiles embed.FS

// ProtectedPath is the protected file every conformance checkout has (committed).
const ProtectedPath = "protected/contract.txt"

// ProtectedContent is its committed content.
const ProtectedContent = "approved contract\n"

// ChildPIDPath is where a spawn_orphan action records the background child's PID.
const ChildPIDPath = ".conformance/child.pid"

// Script is one behavior script.
type Script struct {
	Name string `json:"name"`
	// Only restricts the script to one executor ("" = all).
	Only string `json:"only"`
	// Role is the role the script performs ("" = build). Shape and Review scripts end with a
	// structured submission.
	Role string `json:"role"`
	// Needs lists prevention mechanisms the script's prevention assertion depends on; the
	// assertion is skipped (not the script) when the executor declares none of them.
	Needs  []string      `json:"needs"`
	Rounds []RoundScript `json:"rounds"`
	// DeadlineSeconds sets Task.Deadline relative to the start (0: none).
	DeadlineSeconds float64 `json:"deadline_seconds"`
	// CancelAfterSeconds cancels the round context after this delay (0: never).
	CancelAfterSeconds float64 `json:"cancel_after_seconds"`
	Expect             Expect  `json:"expect"`
}

// RoundScript is what the backend does in one round.
type RoundScript struct {
	Actions []Action `json:"actions"`
	// End is the backend's ending: "finish" or "no_call".
	End   string `json:"end"`
	Claim string `json:"claim"`
	// Usage is reported usage; nil means the backend reports none.
	Usage *ScriptUsage `json:"usage"`
	// Structured is the final result's structured_output (claude-code Shape and Review only).
	// Absent: the backend reports none.
	Structured json.RawMessage `json:"structured,omitempty"`
	// HarnessError makes the backend report an error result (claude-code only).
	HarnessError bool `json:"harness_error"`
	// Malformed makes the backend emit a malformed/unterminated stream (claude-code only).
	Malformed bool `json:"malformed"`
	// APIKeyAuth makes the backend report a non-subscription auth route (claude-code only).
	APIKeyAuth bool `json:"api_key_auth"`
}

// Action is one backend action, performed through the backend's own tools.
type Action struct {
	Write        *WriteAction `json:"write,omitempty"`
	Shell        string       `json:"shell,omitempty"`
	SleepSeconds float64      `json:"sleep_seconds,omitempty"`
	// SpawnOrphan starts `sleep 300` in the background from the backend's shell tool and
	// writes its PID to ChildPIDPath.
	SpawnOrphan bool `json:"spawn_orphan,omitempty"`
}

// WriteAction writes a file with the backend's write/edit tool (not a shell).
type WriteAction struct {
	Path    string `json:"path"`
	Content string `json:"content"`
}

// ScriptUsage is usage the backend reports.
type ScriptUsage struct {
	Input  int `json:"input"`
	Cached int `json:"cached"`
	Output int `json:"output"`
}

// Expect is the shared assertion.
type Expect struct {
	Rounds []ExpectRound `json:"rounds"`
	// Error is "class/reason" of the error the last round returns ("" = none). A prefix
	// ending in "/" matches any reason of that class.
	Error string `json:"error"`
	// Files must exist with exactly this content after the script.
	Files map[string]string `json:"files"`
	// Absent must not exist.
	Absent []string `json:"absent"`
	// Protected is "unchanged" (prevention asserted when Needs are declared), "changed"
	// (documents that this path is not prevented) or "" (not asserted).
	Protected string `json:"protected"`
	// NoLiveChild asserts the spawned orphan was terminated.
	NoLiveChild bool `json:"no_live_child"`
	// FeedbackSeen asserts the backend received each later round's feedback text.
	FeedbackSeen bool `json:"feedback_seen"`
}

// ExpectRound is one round's expected claim.
type ExpectRound struct {
	Ending     executor.Ending `json:"ending"`
	UsageState string          `json:"usage_state"`
	// Structured is the exact (semantically compared) structured submission expected.
	Structured json.RawMessage `json:"structured,omitempty"`
}

// RoleOf is the role a script performs.
func (s Script) RoleOf() string {
	if s.Role == "" {
		return executor.RoleBuild
	}
	return s.Role
}

// SchemaFor is the schema every non-build conformance script submits against.
const SchemaFor = `{"type":"object","additionalProperties":true}`

// Driver makes one executor's backend perform scripts.
type Driver interface {
	// Name is the executor name (executor.Native, executor.ClaudeCode).
	Name() string
	// Prepare readies the backend in root (a committed checkout with ProtectedPath) to
	// perform s, and returns the executor and the base task (Root/Protected/Deadline are
	// set by Run).
	Prepare(t *testing.T, root string, s Script) (executor.Executor, executor.Task)
	// Feedback returns the feedback texts the backend actually received, in order.
	Feedback(t *testing.T) []string
}

// Scripts returns every embedded script, sorted by name.
func Scripts() ([]Script, error) {
	entries, err := scriptFiles.ReadDir("scripts")
	if err != nil {
		return nil, err
	}
	var out []Script
	for _, e := range entries {
		b, err := scriptFiles.ReadFile("scripts/" + e.Name())
		if err != nil {
			return nil, err
		}
		dec := json.NewDecoder(strings.NewReader(string(b)))
		dec.DisallowUnknownFields()
		var s Script
		if err := dec.Decode(&s); err != nil {
			return nil, errors.New(e.Name() + ": " + err.Error())
		}
		if s.Name+".json" != e.Name() {
			return nil, errors.New(e.Name() + ": name does not match the file")
		}
		out = append(out, s)
	}
	slices.SortFunc(out, func(a, b Script) int { return strings.Compare(a.Name, b.Name) })
	return out, nil
}

// Feedback is the feedback text Run sends before round n (n >= 2).
func Feedback(n int) string {
	return "Kogen verification feedback for round " + strconv.Itoa(n) + ": continue."
}

// Run runs every applicable script against d.
func Run(t *testing.T, d Driver) {
	t.Helper()
	scripts, err := Scripts()
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range scripts {
		if s.Only != "" && s.Only != d.Name() {
			continue
		}
		t.Run(s.Name, func(t *testing.T) { runScript(t, d, s) })
	}
}

func runScript(t *testing.T, d Driver, s Script) {
	root := NewCheckout(t)
	ex, task := d.Prepare(t, root, s)
	desc := ex.Describe()
	if err := desc.ValidateRole(s.RoleOf()); err != nil {
		t.Fatalf("descriptor: %v", err)
	}
	if desc.Name != d.Name() {
		t.Fatalf("descriptor name %q, driver %q", desc.Name, d.Name())
	}
	task.Role, task.Root = s.RoleOf(), root
	if task.Role != executor.RoleBuild {
		task.Schema = json.RawMessage(SchemaFor)
	}
	task.Protected = []string{ProtectedPath}
	if s.DeadlineSeconds > 0 {
		task.Deadline = time.Now().Add(time.Duration(s.DeadlineSeconds * float64(time.Second)))
	}
	var events []map[string]any
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	sess, err := ex.Start(ctx, task, func(e map[string]any) { events = append(events, e) })
	var results []executor.RoundResult
	var last error
	if err == nil {
		defer sess.Close()
		for i := range s.Rounds {
			in := executor.Input{}
			if i > 0 {
				in.Feedback = Feedback(i + 1)
			}
			rctx, rcancel := context.WithCancel(ctx)
			if s.CancelAfterSeconds > 0 {
				time.AfterFunc(time.Duration(s.CancelAfterSeconds*float64(time.Second)), rcancel)
			}
			res, rerr := sess.Round(rctx, in)
			rcancel()
			if rerr != nil {
				last = rerr
				break
			}
			results = append(results, res)
		}
	} else {
		last = err
	}
	checkError(t, s.Expect.Error, last)
	if len(results) != len(s.Expect.Rounds) {
		t.Fatalf("rounds: got %d results, want %d (last error %v)", len(results), len(s.Expect.Rounds), last)
	}
	for i, want := range s.Expect.Rounds {
		got := results[i]
		if got.Ending != want.Ending {
			t.Errorf("round %d ending %q, want %q", i+1, got.Ending, want.Ending)
		}
		if want.UsageState != "" && got.Usage.State != want.UsageState {
			t.Errorf("round %d usage state %q, want %q", i+1, got.Usage.State, want.UsageState)
		}
		if got.Usage.State == executor.UsageUnknown && (got.Usage.Input != nil || got.Usage.Output != nil) {
			t.Errorf("round %d: unknown usage carries numbers", i+1)
		}
		if len(want.Structured) > 0 {
			var a, b any
			if json.Unmarshal(want.Structured, &a) != nil || json.Unmarshal(got.Structured, &b) != nil || !reflect.DeepEqual(a, b) {
				t.Errorf("round %d structured %s, want %s", i+1, got.Structured, want.Structured)
			}
		} else if len(got.Structured) > 0 && s.RoleOf() == executor.RoleBuild {
			t.Errorf("round %d: a build round carries a structured submission", i+1)
		}
		if got.Handle.Executor != desc.Name {
			t.Errorf("round %d handle executor %q, want %q", i+1, got.Handle.Executor, desc.Name)
		}
	}
	for p, want := range s.Expect.Files {
		b, err := os.ReadFile(filepath.Join(root, p))
		if err != nil || string(b) != want {
			t.Errorf("file %s = %q (%v), want %q", p, b, err, want)
		}
	}
	for _, p := range s.Expect.Absent {
		if _, err := os.Lstat(filepath.Join(root, p)); err == nil {
			t.Errorf("file %s exists, want absent", p)
		}
	}
	checkProtected(t, s, desc, root)
	if s.Expect.NoLiveChild {
		checkNoChild(t, root)
	}
	if s.Expect.FeedbackSeen {
		seen := d.Feedback(t)
		for i := 1; i < len(s.Rounds); i++ {
			if !slices.Contains(seen, Feedback(i+1)) {
				t.Errorf("backend never received round %d feedback; saw %q", i+1, seen)
			}
		}
	}
	for _, e := range events {
		if name, _ := e["event"].(string); !strings.HasPrefix(name, "executor_") {
			t.Errorf("event %v is not an executor_* event", e)
		}
	}
}

func checkError(t *testing.T, want string, got error) {
	t.Helper()
	if want == "" {
		if got != nil {
			t.Fatalf("unexpected error: %v", got)
		}
		return
	}
	if got == nil {
		t.Fatalf("no error, want %s", want)
	}
	e, ok := sys.AsError(got)
	if !ok {
		t.Fatalf("error %v (%T) is not a typed *sys.Error, want %s", got, got, want)
	}
	actual := e.Class + "/" + e.Reason
	if strings.HasSuffix(want, "/") {
		if !strings.HasPrefix(actual, want) {
			t.Fatalf("error %s, want class %s", actual, want)
		}
	} else if actual != want {
		t.Fatalf("error %s, want %s", actual, want)
	}
}

func checkProtected(t *testing.T, s Script, d executor.Descriptor, root string) {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(root, ProtectedPath))
	changed := err != nil || string(b) != ProtectedContent
	switch s.Expect.Protected {
	case "unchanged":
		if len(s.Needs) > 0 && !slices.ContainsFunc(s.Needs, func(n string) bool {
			return slices.Contains(d.Capabilities.Prevention, n)
		}) {
			// No listed prevention is declared: detection is Kogen's job, not asserted here.
			return
		}
		if changed {
			t.Errorf("protected file changed despite declared prevention %v", d.Capabilities.Prevention)
		}
	case "changed":
		if !changed {
			t.Errorf("protected file unchanged; this script documents a path executors do not prevent")
		}
	}
}

func checkNoChild(t *testing.T, root string) {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(root, ChildPIDPath))
	if err != nil {
		t.Fatalf("child PID not recorded: %v", err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(b)))
	if err != nil || pid <= 1 {
		t.Fatalf("bad child PID %q", b)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		if syscall.Kill(pid, 0) != nil {
			return
		}
		if time.Now().After(deadline) {
			syscall.Kill(pid, syscall.SIGKILL)
			t.Fatalf("background child %d outlived the round", pid)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// NewCheckout makes a committed Git checkout with README.md and ProtectedPath.
func NewCheckout(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	if r, err := filepath.EvalSymlinks(root); err == nil {
		root = r
	}
	must := func(args ...string) {
		cmd := exec.Command("git", args...)
		cmd.Dir = root
		cmd.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null",
			"GIT_AUTHOR_NAME=c", "GIT_AUTHOR_EMAIL=c@example.invalid", "GIT_COMMITTER_NAME=c", "GIT_COMMITTER_EMAIL=c@example.invalid")
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	if err := os.MkdirAll(filepath.Join(root, "protected"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "README.md"), []byte("# Conformance\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, ProtectedPath), []byte(ProtectedContent), 0o644); err != nil {
		t.Fatal(err)
	}
	must("init", "-q", "-b", "main")
	must("add", "-A")
	must("commit", "-q", "--no-gpg-sign", "-m", "Initial commit")
	return root
}

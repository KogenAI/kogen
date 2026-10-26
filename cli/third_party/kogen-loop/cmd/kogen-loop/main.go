// Command kogen-loop is the standalone process protocol of kogen-loop (contract kogen-loop/v1,
// docs/contract/loop-v1.md): one task in, JSON Lines events out, an exit code.
//
//	kogen-loop capabilities --json
//	kogen-loop version
//	kogen-loop run --task FILE|-
//
// A round ending is the model's claim, never proof that the work is done.
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
	"time"

	"kogen-loop/api"
	"kogen-loop/loop"
	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen-loop/tools"
)

// version is the module version label; release builds set it with -ldflags "-X main.version=...".
var version = "dev"

func main() {
	// A killed host must still take its command groups down (contract L6): the supervisor
	// hook comes before anything else.
	sys.MaybeSupervise(os.Args[1:])
	sys.EnableSupervisor()
	os.Exit(run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr))
}

func run(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, usage)
		return api.ExitInvalid
	}
	switch args[0] {
	case "version":
		if len(args) != 1 {
			fmt.Fprintln(stderr, usage)
			return api.ExitInvalid
		}
		fmt.Fprintln(stdout, "kogen-loop "+version)
		return 0
	case "capabilities":
		fs := flag.NewFlagSet("capabilities", flag.ContinueOnError)
		fs.SetOutput(stderr)
		fs.Bool("json", true, "print the capabilities as JSON (the only format)")
		if err := fs.Parse(args[1:]); err != nil || fs.NArg() != 0 {
			fmt.Fprintln(stderr, usage)
			return api.ExitInvalid
		}
		data, _ := json.Marshal(capabilities())
		fmt.Fprintf(stdout, "%s\n", data)
		return 0
	case "run":
		return runTask(args[1:], stdin, stdout, stderr)
	}
	fmt.Fprintln(stderr, usage)
	return api.ExitInvalid
}

const usage = "usage: kogen-loop capabilities --json | version | run --task FILE|-"

// genericTools are the tools the standalone loop offers by name.
var genericTools = []string{
	tools.ReadFileTool, tools.WriteFileTool, tools.ListFilesTool, tools.SearchTextTool,
	tools.ShellTool, tools.ViewImageTool, tools.DocumentationTool,
}

func capabilities() api.Capabilities {
	var providers []string
	for _, p := range provider.Catalog() {
		providers = append(providers, p.Name)
	}
	return api.Capabilities{
		Protocol: api.Protocol, Library: api.Library, Version: version,
		Providers: providers, Tools: genericTools, TerminalDefault: loop.DefaultTerminal,
		SessionResume: "transcript", ContextPolicies: []string{"fail_over_budget"},
		Usage: "provider", Images: true, Subagents: false, Compaction: false,
	}
}

func capabilitiesDigest() string {
	data, _ := json.Marshal(capabilities())
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

// provided are the capability names a task may require and whether kogen-loop has them.
var provided = map[string]bool{
	api.CapSessionResume: true,
	api.CapImages:        true,
	api.CapSubagents:     false,
	api.CapCompaction:    false,
}

// emitter writes the JSON Lines events: one write per event, a gapless sequence, UTC time.
type emitter struct {
	mu  sync.Mutex
	w   io.Writer
	log io.Writer
	seq int
}

func (e *emitter) emit(typ string, fields map[string]any) {
	e.mu.Lock()
	defer e.mu.Unlock()
	line, err := json.Marshal(api.Event{
		Protocol: api.Protocol, Seq: e.seq + 1, Time: time.Now().UTC().Format(time.RFC3339), Type: typ, Fields: fields,
	})
	if err != nil {
		fmt.Fprintf(e.log, "kogen-loop: dropped a %s event: %v\n", typ, err)
		return
	}
	e.seq++
	e.w.Write(append(line, '\n'))
}

func (e *emitter) failure(err error) {
	class, reason, detail := api.ErrClassLoop, "failed", err.Error()
	if se, ok := sys.AsError(err); ok {
		class, reason, detail = se.Class, se.Reason, se.Detail
	}
	e.emit(api.EventError, map[string]any{"class": class, "reason": reason, "detail": detail})
}

// exitOf is the exit code of a failure: 2 for a refused task, 1 for everything else.
func exitOf(err error) int {
	if se, ok := sys.AsError(err); ok && se.Class == api.ErrClassLoop && se.Exit == api.ExitInvalid {
		return api.ExitInvalid
	}
	return api.ExitFailed
}

func runTask(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	out := &emitter{w: stdout, log: stderr}
	s := sys.New()
	// Stdout carries events and nothing else.
	s.Stdout, s.Stderr = stderr, stderr
	stopSignals := s.WatchSignals()
	defer stopSignals()

	status, exit := execute(args, stdin, stderr, s, out)
	out.emit(api.EventSessionEnded, map[string]any{"status": status, "exit": exit})
	return exit
}

// execute runs the task and returns the session.ended status and exit code. Every failure
// path emits its error event first.
func execute(args []string, stdin io.Reader, stderr io.Writer, s *sys.Session, out *emitter) (string, int) {
	refuse := func(err error) (string, int) {
		out.failure(err)
		return api.StatusFailed, exitOf(err)
	}
	fs := flag.NewFlagSet("run", flag.ContinueOnError)
	fs.SetOutput(stderr)
	taskPath := fs.String("task", "", "the task: a JSON file, or - for standard input")
	if err := fs.Parse(args); err != nil || fs.NArg() != 0 || *taskPath == "" {
		return refuse(sys.Fail(api.ErrClassLoop, api.ErrInvalidTask, usage, api.ExitInvalid))
	}
	task, err := readTask(*taskPath, stdin)
	if err != nil {
		return refuse(err)
	}
	for _, name := range task.Requires {
		if !provided[name] {
			return refuse(sys.Fail(api.ErrClassLoop, api.ErrUnsupportedCapability,
				fmt.Sprintf("the task requires %q, which kogen-loop does not provide", name), api.ExitInvalid))
		}
	}
	root, err := validateTask(task)
	if err != nil {
		return refuse(err)
	}

	ctx := s.Context()
	if task.DeadlineSeconds > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, time.Duration(task.DeadlineSeconds)*time.Second)
		defer cancel()
	}

	cfg := loop.SessionConfig{
		Root: root, Role: provider.Role{Provider: task.Role.Provider, Model: task.Role.Model, Effort: task.Role.Effort, BaseURL: task.Role.BaseURL},
		Instructions: task.Instructions, Enabled: task.Tools, Protected: task.Protected, Excluded: task.Excluded,
		Terminal: task.Terminal, Dir: task.Session.Dir,
		Client:  provider.NewClient("kogen-loop " + version),
		Session: s,
		Emit:    func(e api.Event) { out.emit(e.Type, e.Fields) },
	}
	var sess *loop.Session
	if task.Session.Resume {
		sess, err = loop.ResumeSession(cfg)
	} else {
		sess, err = loop.NewSession(cfg)
	}
	if err != nil {
		return refuse(err)
	}
	home := s.Getenv("HOME")
	if home == "" {
		return refuse(sys.Fail("provider", "login", "HOME is not set; the stored login cannot be found", api.ExitFailed))
	}
	if err := provider.RequireLogin(home, []provider.Role{cfg.Role}); err != nil {
		return refuse(err)
	}
	out.emit(api.EventSessionStarted, map[string]any{
		"session_id": sess.ID(), "resumed": task.Session.Resume, "role": task.Role,
		"capabilities_digest": capabilitiesDigest(),
	})

	_, err = sess.Round(ctx, task.Prompt)
	if err == nil {
		return api.StatusEnded, api.ExitEnded
	}
	if ie := s.Err(); ie != nil {
		// Every command group stops before the process does (contract L6).
		sys.Terminate(s.Groups())
		code := api.ExitInterrupted
		var in *sys.Interrupted
		if errors.As(ie, &in) {
			code = in.ExitCode()
		}
		return api.StatusInterrupted, code
	}
	if task.DeadlineSeconds > 0 && errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return refuse(sys.Fail(api.ErrClassLoop, api.ErrDeadline,
			fmt.Sprintf("the round did not end within %d seconds", task.DeadlineSeconds), api.ExitFailed))
	}
	return refuse(err)
}

func readTask(path string, stdin io.Reader) (api.Task, error) {
	var data []byte
	var err error
	if path == "-" {
		data, err = io.ReadAll(stdin)
	} else {
		data, err = os.ReadFile(path)
	}
	if err != nil {
		return api.Task{}, sys.Fail(api.ErrClassLoop, api.ErrInvalidTask, "cannot read the task: "+err.Error(), api.ExitInvalid)
	}
	// A task of another protocol is refused as such before its fields are judged.
	var peek struct {
		Protocol *string `json:"protocol"`
	}
	if json.Unmarshal(data, &peek) == nil && peek.Protocol != nil && *peek.Protocol != api.Protocol {
		return api.Task{}, unsupportedProtocol(*peek.Protocol)
	}
	task, err := api.DecodeTask(bytes.NewReader(data))
	if err != nil {
		return api.Task{}, sys.Fail(api.ErrClassLoop, api.ErrInvalidTask, err.Error(), api.ExitInvalid)
	}
	if task.Protocol != api.Protocol {
		return api.Task{}, unsupportedProtocol(task.Protocol)
	}
	return task, nil
}

func unsupportedProtocol(got string) error {
	return sys.Fail(api.ErrClassLoop, api.ErrUnsupportedProtocol,
		fmt.Sprintf("the task has protocol %q; this build speaks %q", got, api.Protocol), api.ExitInvalid)
}

// validateTask checks the fields the loop itself judges and returns the absolute root.
func validateTask(t api.Task) (string, error) {
	bad := func(detail string) (string, error) {
		return "", sys.Fail(api.ErrClassLoop, api.ErrInvalidTask, detail, api.ExitInvalid)
	}
	if t.Root == "" {
		return bad("root is required")
	}
	root, err := filepath.Abs(t.Root)
	if err != nil {
		return bad("root: " + err.Error())
	}
	if st, err := os.Stat(root); err != nil || !st.IsDir() {
		return bad("root must be an existing directory: " + t.Root)
	}
	if t.Prompt == "" {
		return bad("prompt is required")
	}
	if t.DeadlineSeconds < 0 {
		return bad("deadline_seconds must not be negative")
	}
	if t.Session.Resume && t.Session.Dir == "" {
		return bad("session.resume needs session.dir")
	}
	if _, ok := provider.Lookup(t.Role.Provider); !ok {
		return bad("unknown provider " + t.Role.Provider)
	}
	return root, nil
}

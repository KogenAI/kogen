package verify

import (
	"context"
	"os"
	"path/filepath"
	"strings"

	"kogen/sys"
)

// Tools are Kogen's own Node, Quint and Cucumber, as recorded at install (INS-4, LOOP-12).
// Commands get them as KOGEN_NODE, KOGEN_QUINT and KOGEN_CUCUMBER next to the caller's
// environment. Quint always runs on this Node, never on the caller's PATH.
type Tools struct {
	Node     string // the node executable
	Quint    string // quint's cli.js
	Cucumber string // the node_modules folder holding @cucumber/cucumber
}

// ToolsFromInstall resolves the tools of an installed Kogen: installRoot/node-path names the
// Node (the file's own path when unreadable), Quint and Cucumber live under installRoot/lib.
func ToolsFromInstall(installRoot string) Tools {
	node := filepath.Join(installRoot, "node-path")
	if b, err := os.ReadFile(node); err == nil {
		node = strings.TrimSpace(string(b))
	}
	return Tools{
		Node:     node,
		Quint:    filepath.Join(installRoot, "lib/quint/node_modules/@informalsystems/quint/dist/src/cli.js"),
		Cucumber: filepath.Join(installRoot, "lib/cucumber/node_modules"),
	}
}

func (t Tools) env() map[string]string {
	env := map[string]string{}
	for k, v := range map[string]string{"KOGEN_NODE": t.Node, "KOGEN_QUINT": t.Quint, "KOGEN_CUCUMBER": t.Cucumber} {
		if v != "" {
			env[k] = v
		}
	}
	return env
}

// Require refuses when Node or Quint is missing (VER-5).
func (t Tools) Require() error {
	if !isRegular(t.Node) {
		return sys.Fail("environment", "tool_missing", "node is not available at "+t.Node+"; reinstall Kogen", 3)
	}
	if !isRegular(t.Quint) {
		return sys.Fail("environment", "tool_missing", "quint is not available at "+t.Quint+"; reinstall Kogen", 3)
	}
	return nil
}

func isRegular(path string) bool {
	st, err := os.Stat(path)
	return err == nil && st.Mode().IsRegular()
}

// Logger receives the run log's events; the implementation stamps the time (`at`) and
// writes one JSON line. A nil Logger records nothing.
type Logger interface{ Log(event map[string]any) }

func logEvent(l Logger, event map[string]any) {
	if l != nil {
		l.Log(event)
	}
}

// Evidence receives the shaping evidence of native checks: how often setup, acceptance and
// Quint ran, the time spent in setup, and the probes behind declared feasibility evidence.
// The shape package implements it; a nil Evidence records nothing.
type Evidence interface {
	// Count notes one execution of "setup", "acceptance" or "quint".
	Count(kind string)
	// Timed runs fn and records its duration under phase ("setup").
	Timed(phase string, fn func() error) error
	// Probe runs one declared check, recording its result as a probe_result event.
	Probe(fn func() (ProbeResult, error)) (ProbeResult, error)
	// Record appends an event (feasibility_check).
	Record(event map[string]any)
}

func count(e Evidence, kind string) {
	if e != nil {
		e.Count(kind)
	}
}

func timed(e Evidence, phase string, fn func() error) error {
	if e == nil {
		return fn()
	}
	return e.Timed(phase, fn)
}

func probed(e Evidence, fn func() (ProbeResult, error)) (ProbeResult, error) {
	if e == nil {
		return fn()
	}
	return e.Probe(fn)
}

func record(e Evidence, event map[string]any) {
	if e != nil {
		e.Record(event)
	}
}

// run runs one command with the tools' environment next to the caller's and stops when ctx
// is done.
func run(ctx context.Context, s *sys.Session, tools Tools, command, dir string, extra map[string]string) (sys.Result, error) {
	if err := ctx.Err(); err != nil {
		// The caller's interrupt is the error, so it exits with its signal code (LOOP-5).
		if ie := s.Err(); ie != nil {
			return sys.Result{}, ie
		}
		return sys.Result{}, err
	}
	env := tools.env()
	for k, v := range extra {
		env[k] = v
	}
	return s.Run(command, dir, sys.Options{Env: env})
}

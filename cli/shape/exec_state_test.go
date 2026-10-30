package shape

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"kogen-loop/sys"
	"kogen/executor"
	"kogen/project"
)

// hooksDir is the fixture's effective hooks directory (the fixture sets a private core.hooksPath).
func (f *shpFx) hooksDir() string {
	return strings.TrimSpace(f.git("config", "--get", "core.hooksPath"))
}

// plant writes an executable hook that records any run in a marker the test inspects.
func (f *shpFx) plant(name string) string {
	f.t.Helper()
	marker := filepath.Join(f.Aux, "ran-"+name)
	hook := filepath.Join(f.hooksDir(), name)
	if err := os.WriteFile(hook, []byte("#!/bin/sh\nprintf ran >> '"+marker+"'\n"), 0o755); err != nil {
		f.t.Fatal(err)
	}
	return marker
}

func notRun(t *testing.T, marker string) {
	t.Helper()
	if _, err := os.Stat(marker); err == nil {
		t.Fatal("a planted hook or configured program ran")
	}
}

func wantStateRefusal(t *testing.T, err error, reason string, names ...string) {
	t.Helper()
	se, ok := sys.AsError(err)
	if !ok || se.Class != "candidate" || se.Reason != reason {
		t.Fatalf("error %v, want candidate/%s", err, reason)
	}
	for _, n := range names {
		if !strings.Contains(se.Detail, n) {
			t.Fatalf("refusal %q does not name %q", se.Detail, n)
		}
	}
}

// startMutating is a scripted executor whose Start, not a round, touches the Git execution state.
type startMutating struct {
	*shapeExec
	onStart  func()
	startErr error
}

func (s startMutating) Start(ctx context.Context, t executor.Task, emit executor.Sink) (executor.Session, error) {
	s.onStart()
	if s.startErr != nil {
		return nil, s.startErr
	}
	return s.shapeExec.Start(ctx, t, emit)
}

func (s startMutating) external() External {
	return func(project.Role) (executor.Executor, error) { return s, nil }
}

// TestShapeExecutionStateBoundary: the pin of hooks and executable-selecting configuration is
// compared at every external boundary, before any later Git command: startup (also a failed one),
// a later round, a round that fails, and the audit session; the refusal names the path or key,
// publishes nothing and runs nothing.
func TestShapeExecutionStateBoundary(t *testing.T) {
	t.Run("startup", func(t *testing.T) {
		for name, startErr := range map[string]error{"successful": nil, "failed": errors.New("executor failed to start")} {
			t.Run(name, func(t *testing.T) {
				f := newShpFx(t)
				f.useExternalShape(6)
				var marker string
				x := startMutating{shapeExec: &shapeExec{t: t, rounds: []func(int, string) (executor.RoundResult, error){result(shpFiles())}},
					onStart: func() { marker = f.plant("commit-msg") }, startErr: startErr}
				f.newSession()
				_, err := Shape(context.Background(), f.S, ShapeInput{Project: f.Root, Slug: shpSlug, Request: "Add calc.is_even(n).", Client: f.Client, External: x.external()})
				wantStateRefusal(t, err, "execution_state_changed", "commit-msg")
				notRun(t, marker)
				shapeAbsent(t, f)
				if len(x.inputs) != 0 {
					t.Fatal("a round ran after the startup mutation")
				}
			})
		}
	})
	t.Run("a later round", func(t *testing.T) {
		f := newShpFx(t)
		f.useExternalShape(6)
		var marker string
		x := &shapeExec{t: t, rounds: []func(int, string) (executor.RoundResult, error){
			result(map[string]any{"files": []any{}}),
			func(n int, root string) (executor.RoundResult, error) {
				marker = f.plant("pre-commit")
				return result(shpFiles())(n, root)
			}}}
		_, err := f.shapeWith(x, "Add calc.is_even(n).")
		wantStateRefusal(t, err, "execution_state_changed", "pre-commit")
		if x.calls != 2 {
			t.Fatalf("%d rounds, want the mutation in the second", x.calls)
		}
		notRun(t, marker)
		shapeAbsent(t, f)
	})
	t.Run("a failed round", func(t *testing.T) {
		f := newShpFx(t)
		f.useExternalShape(6)
		var marker string
		x := &shapeExec{t: t, rounds: []func(int, string) (executor.RoundResult, error){
			func(int, string) (executor.RoundResult, error) {
				marker = f.plant("commit-msg")
				return executor.RoundResult{}, executor.Fail(executor.ReasonProtocol, "the session crashed")
			}}}
		_, err := f.shapeWith(x, "Add calc.is_even(n).")
		wantStateRefusal(t, err, "execution_state_changed", "commit-msg")
		notRun(t, marker)
		shapeAbsent(t, f)
	})
	t.Run("selected executables and unreadable state", func(t *testing.T) {
		cases := map[string]struct {
			mutate func(f *shpFx)
			reason string
			name   string
		}{
			"core.fsmonitor":     {func(f *shpFx) { f.git("config", "core.fsmonitor", f.plant("monitor-"+"x")) }, "execution_state_changed", "core.fsmonitor"},
			"alias":              {func(f *shpFx) { f.git("config", "alias.audit", "!true") }, "execution_state_changed", "alias.audit"},
			"credential.helper":  {func(f *shpFx) { f.git("config", "--add", "credential.helper", "true") }, "execution_state_changed", "credential.helper"},
			"malformed config":   {func(f *shpFx) { f.write(".git/config", f.read(".git/config")+"[core\n") }, "execution_state_unreadable", "configuration"},
			"hooks path removed": {func(f *shpFx) { f.git("config", "--unset-all", "core.hooksPath") }, "execution_state_changed", "core.hooksPath"},
		}
		for name, c := range cases {
			t.Run(name, func(t *testing.T) {
				f := newShpFx(t)
				f.useExternalShape(6)
				x := &shapeExec{t: t, rounds: []func(int, string) (executor.RoundResult, error){
					func(n int, root string) (executor.RoundResult, error) {
						c.mutate(f)
						return result(shpFiles())(n, root)
					}}}
				_, err := f.shapeWith(x, "Add calc.is_even(n).")
				wantStateRefusal(t, err, c.reason, c.name)
				shapeAbsent(t, f)
			})
		}
	})
	t.Run("the audit session", func(t *testing.T) {
		f := newShpFx(t)
		f.useExternalShape(6)
		f.write(".kogen/project.yaml", f.read(".kogen/project.yaml")+"shape_audit:\n  enabled: true\n")
		f.git("add", ".kogen/project.yaml")
		f.git("commit", "-qm", "audit")
		var marker string
		x := &shapeExec{t: t, rounds: []func(int, string) (executor.RoundResult, error){
			func(n int, root string) (executor.RoundResult, error) {
				marker = f.plant("commit-msg")
				return result(map[string]any{"examples": []any{}, "rules": []any{}, "cells": []any{}, "defects": []any{}})(n, root)
			}}}
		_, err := f.shapeWith(x, "Add calc.is_even(n).")
		wantStateRefusal(t, err, "execution_state_changed", "commit-msg")
		notRun(t, marker)
		shapeAbsent(t, f)
	})
	t.Run("config values are never named", func(t *testing.T) {
		f := newShpFx(t)
		f.useExternalShape(6)
		x := &shapeExec{t: t, rounds: []func(int, string) (executor.RoundResult, error){
			func(n int, root string) (executor.RoundResult, error) {
				f.git("config", "core.sshCommand", "ssh -i /secret/token-value")
				return result(shpFiles())(n, root)
			}}}
		_, err := f.shapeWith(x, "Add calc.is_even(n).")
		wantStateRefusal(t, err, "execution_state_changed", "core.sshCommand")
		if strings.Contains(f.Stdout.String()+f.Stderr.String()+err.Error(), "token-value") {
			t.Fatal("a configuration value was printed")
		}
	})
}

// TestRefineExecutionStateBoundary: an external Refine round is bracketed by the same comparison;
// the correction is refused, the package and approval are preserved and nothing runs.
func TestRefineExecutionStateBoundary(t *testing.T) {
	for name, mutate := range map[string]func(f *refFx) string{
		"planted hook": func(f *refFx) string { return f.plant("commit-msg") },
		"filter": func(f *refFx) string {
			f.git("config", "filter.audit.clean", "true")
			return ""
		},
	} {
		t.Run(name, func(t *testing.T) {
			f := newRefFx(t, refOpts{approved: true, external: 6})
			before, approval, head := f.pkg(), f.read(".kogen/local/approvals/is-even.json"), f.head()
			var marker string
			x := &shapeExec{t: t, rounds: []func(int, string) (executor.RoundResult, error){
				func(n int, root string) (executor.RoundResult, error) {
					marker = mutate(f)
					return result(map[string]any{"files": []any{map[string]any{"path": refIntentPath, "content": refTitled}}})(n, root)
				}}}
			_, err := f.refineWith(x, f.hash0)
			if name == "filter" {
				wantStateRefusal(t, err, "execution_state_changed", "filter.audit.clean")
			} else {
				wantStateRefusal(t, err, "execution_state_changed", "commit-msg")
				notRun(t, marker)
			}
			refEqual(t, "package", f.pkg(), before)
			shpEq(t, "approval", f.read(".kogen/local/approvals/is-even.json"), approval)
			shpEq(t, "HEAD", f.head(), head)
			noNativeRequests(t, f.shpFx)
		})
	}
	t.Run("startup", func(t *testing.T) {
		f := newRefFx(t, refOpts{approved: true, external: 6})
		before := f.pkg()
		var marker string
		x := startMutating{shapeExec: &shapeExec{t: t, rounds: []func(int, string) (executor.RoundResult, error){result(map[string]any{"files": []any{}})}},
			onStart: func() { marker = f.plant("commit-msg") }, startErr: errors.New("executor failed to start")}
		f.newSession()
		_, err := Refine(context.Background(), f.S, RefineInput{Project: f.Root, Slug: shpSlug, Hash: f.hash0,
			Request: "Clarify only the existing draft; preserve its executable contract.", RequestPath: filepath.Join(f.Aux, "correction.txt"),
			Client: f.Client, External: x.external()})
		wantStateRefusal(t, err, "execution_state_changed", "commit-msg")
		notRun(t, marker)
		refEqual(t, "package", f.pkg(), before)
	})
}

package contract_test

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"kogen-loop/provider"
	"kogen-loop/sys"
)

// waitFor polls until ok is true or a bounded deadline passes.
func waitFor(t *testing.T, what string, ok func() bool) {
	t.Helper()
	for deadline := time.Now().Add(10 * time.Second); time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
		if ok() {
			return
		}
	}
	t.Fatalf("%s did not happen within 10 seconds", what)
}

// TestProviderCatalog pins the provider list and each provider's default model: kogen-setup
// setup/init_route.go takes Models[0] of every Catalog entry as a route's default model.
func TestProviderCatalog(t *testing.T) {
	var names []string
	defaults := map[string]string{}
	for _, info := range provider.Catalog() {
		names = append(names, info.Name)
		if len(info.Models) > 0 {
			defaults[info.Name] = info.Models[0]
		}
	}
	if want := []string{"chatgpt", "supergrok", "opencode-go", "anthropic", "openai-compatible"}; !reflect.DeepEqual(names, want) {
		t.Fatalf("Catalog names = %v, want %v", names, want)
	}
	want := map[string]string{"supergrok": "grok-4.7", "opencode-go": "kimi-k3", "anthropic": "claude-opus-5-5"}
	if !reflect.DeepEqual(defaults, want) {
		t.Fatalf("default models = %v, want %v: chatgpt and openai-compatible have no Models", defaults, want)
	}
}

// TestSysRunContextCompletes pins that RunContext of a command that completes returns what Run
// returns and honours Options.Env. Adapted from kogen-verification verify/probe.go,
// verify/attempt.go and verify/env.go and kogen-shaping shape/unpassable.go.
func TestSysRunContextCompletes(t *testing.T) {
	s, _, _ := newSession(t)
	r, err := s.RunContext(context.Background(), "printf out; exit 3", s.Cwd, sys.Options{})
	if err != nil || r.Status != 3 || r.Output != "out" {
		t.Fatalf("RunContext = %+v, %v", r, err)
	}
	r, err = s.RunContext(context.Background(), `printf "$X"`, s.Cwd, sys.Options{Env: map[string]string{"X": "from-options"}})
	if err != nil || r.Status != 0 || r.Output != "from-options" {
		t.Fatalf("RunContext with Options.Env = %+v, %v", r, err)
	}
}

// TestSysRunContextCancel pins that a cancelled context discards the partial output: the
// result is the zero Result and the error is context.Canceled. Adapted from kogen-verification
// verify/concurrent.go. The test cancels only once the command has written its ready file.
func TestSysRunContextCancel(t *testing.T) {
	s, _, _ := newSession(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	type outcome struct {
		r   sys.Result
		err error
	}
	done := make(chan outcome, 1)
	go func() {
		r, err := s.RunContext(ctx, "printf partial; touch ready; exec sleep 30", s.Cwd, sys.Options{})
		done <- outcome{r, err}
	}()
	waitFor(t, "the command's ready file", func() bool {
		_, err := os.Stat(filepath.Join(s.Cwd, "ready"))
		return err == nil
	})
	cancel()
	select {
	case got := <-done:
		if got.r != (sys.Result{}) || !errors.Is(got.err, context.Canceled) {
			t.Fatalf("RunContext after cancel = %+v, %v", got.r, got.err)
		}
	case <-time.After(20 * time.Second):
		t.Fatal("RunContext did not return after its context was cancelled")
	}
}

// TestSysCapturedPartialAndFinished pins the snapshots of a captured command while it runs and
// after it ends. Adapted from kogen-verification verify/concurrent.go.
func TestSysCapturedPartialAndFinished(t *testing.T) {
	s, _, _ := newSession(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	running := s.StartCaptured(ctx, "printf partial; exec sleep 30", s.Cwd)
	waitFor(t, "the partial output", func() bool {
		r, _, _ := running.Snapshot()
		return r.Output == "partial"
	})
	r, finished, err := running.Snapshot()
	if r != (sys.Result{Output: "partial"}) || finished || err != nil {
		t.Fatalf("Snapshot while running = %+v, %v, %v", r, finished, err)
	}
	select {
	case <-running.Done():
		t.Fatal("Done is closed while the command runs")
	default:
	}
	running.Stop(cancel)

	ended := s.StartCaptured(context.Background(), "printf done; exit 3", s.Cwd)
	select {
	case <-ended.Done():
	case <-time.After(20 * time.Second):
		t.Fatal("Done was not closed when the command ended")
	}
	r, finished, err = ended.Snapshot()
	if r.Status != 3 || r.Output != "done" || !finished || err != nil {
		t.Fatalf("Snapshot after the command ended = %+v, %v, %v", r, finished, err)
	}
}

// TestSysCapturedStop pins that Stop calls cancel and joins the command: afterwards Done is
// closed and the snapshot is the zero Result, finished, with context.Canceled. Adapted from
// kogen-verification verify/concurrent.go.
func TestSysCapturedStop(t *testing.T) {
	s, _, _ := newSession(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	c := s.StartCaptured(ctx, "printf partial; touch ready; exec sleep 30", s.Cwd)
	waitFor(t, "the command's ready file", func() bool {
		_, err := os.Stat(filepath.Join(s.Cwd, "ready"))
		return err == nil
	})
	called := false
	c.Stop(func() { called = true; cancel() })
	if !called {
		t.Fatal("Stop did not call cancel")
	}
	select {
	case <-c.Done():
	default:
		t.Fatal("Done is not closed when Stop returns")
	}
	r, finished, err := c.Snapshot()
	if r != (sys.Result{}) || !finished || !errors.Is(err, context.Canceled) {
		t.Fatalf("Snapshot after Stop = %+v, %v, %v", r, finished, err)
	}
}

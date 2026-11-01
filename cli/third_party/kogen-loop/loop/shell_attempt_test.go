package loop

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"testing"

	"kogen-loop/sys"
	"kogen-loop/tools"
)

func TestDiscardedAttemptStopsYieldedShell(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	tl := &tools.Tools{Root: root, Session: sys.NewWith(os.Environ(), root), Enabled: []string{tools.ShellTool}}
	defer tl.EndShellRound()
	st := newStage(context.Background(), tl, nil)
	st.Done(0, olShell("c", "while :; do sleep 1; done"))
	st.mu.Lock()
	g := st.gen
	for len(g.slots) == 0 || g.slots[0].state != finished {
		st.cond.Wait()
	}
	text := g.slots[0].out.Text
	st.mu.Unlock()
	var result struct {
		Status string `json:"status"`
		Handle string `json:"handle"`
	}
	if err := json.Unmarshal([]byte(text), &result); err != nil || result.Status != "running" || result.Handle == "" {
		t.Fatalf("yield: %q %v", text, err)
	}
	st.Abort()
	out, err := tl.Run(tools.ShellTool, map[string]any{"handle": result.Handle})
	if err != nil || out.Text != "error: unknown shell handle" {
		t.Fatalf("discarded handle: %q %v", out.Text, err)
	}
}

// A yielded leader may finish before its attempt is discarded, leaving a child.
func TestDiscardedAttemptStopsCompletedYieldedShell(t *testing.T) {
	root := t.TempDir()
	tl := &tools.Tools{Root: root, Session: sys.NewWith(os.Environ(), root), Enabled: []string{tools.ShellTool}}
	defer tl.EndShellRound()
	st := newStage(context.Background(), tl, nil)
	st.Done(0, olShell("c", `sleep 600 >/dev/null 2>&1 & echo $! > child.pid; sleep 2`))
	st.mu.Lock()
	g := st.gen
	for len(g.slots) == 0 || g.slots[0].state != finished {
		st.cond.Wait()
	}
	text := g.slots[0].out.Text
	st.mu.Unlock()
	var result struct {
		Status string `json:"status"`
		Handle string `json:"handle"`
	}
	if err := json.Unmarshal([]byte(text), &result); err != nil || result.Status != "running" || result.Handle == "" {
		t.Fatalf("yield: %q %v", text, err)
	}
	data, err := os.ReadFile(filepath.Join(root, "child.pid"))
	if err != nil {
		t.Fatal(err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { sys.Terminate(tl.Session.LiveGroups()) })
	out, err := tl.Run(tools.ShellTool, map[string]any{"handle": result.Handle})
	if err != nil {
		t.Fatal(err)
	}
	var complete struct {
		Status string `json:"status"`
	}
	if err := json.Unmarshal([]byte(out.Text), &complete); err != nil || complete.Status != "completed" {
		t.Fatalf("completion: %q %v", out.Text, err)
	}
	live := func() bool {
		out, err := exec.Command("ps", "-o", "stat=", "-p", strconv.Itoa(pid)).Output()
		return err == nil && len(strings.Fields(string(out))) > 0 && !strings.HasPrefix(strings.TrimSpace(string(out)), "Z")
	}
	if !live() {
		t.Fatal("child did not survive between calls")
	}
	st.Abort()
	if live() {
		t.Fatal("child survived discarded attempt")
	}
}

// A command can finish before yielding while leaving work in its group.
func TestDiscardedAttemptStopsFastShellChild(t *testing.T) {
	root := t.TempDir()
	tl := &tools.Tools{Root: root, Session: sys.NewWith(os.Environ(), root), Enabled: []string{tools.ShellTool}}
	defer tl.EndShellRound()
	st := newStage(context.Background(), tl, nil)
	st.Done(0, olShell("c", `sleep 600 >/dev/null 2>&1 & echo $! > child.pid`))
	st.mu.Lock()
	g := st.gen
	for len(g.slots) == 0 || g.slots[0].state != finished {
		st.cond.Wait()
	}
	text := g.slots[0].out.Text
	st.mu.Unlock()
	if !strings.HasPrefix(text, "exit status: 0") {
		t.Fatalf("fast shell: %q", text)
	}
	data, err := os.ReadFile(filepath.Join(root, "child.pid"))
	if err != nil {
		t.Fatal(err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { sys.Terminate(tl.Session.LiveGroups()) })
	live := func() bool {
		out, err := exec.Command("ps", "-o", "stat=", "-p", strconv.Itoa(pid)).Output()
		return err == nil && len(strings.Fields(string(out))) > 0 && !strings.HasPrefix(strings.TrimSpace(string(out)), "Z")
	}
	if !live() {
		t.Fatal("child did not survive command")
	}
	st.Abort()
	if live() {
		t.Fatal("child survived discarded attempt")
	}
}

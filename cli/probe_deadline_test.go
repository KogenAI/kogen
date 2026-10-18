package main

import (
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// TestInstalledProbeDeadline is invoked by the acceptance suite's compiled Go test
// binary. It exercises the unmodified installed core and the real session executor.
// Only the observed probe request's deadline is contracted, after checking the
// production five-minute policy. No timeout reply or elapsed time is fabricated.
func TestInstalledProbeDeadline(t *testing.T) {
	if os.Getenv("KOGEN_TEST_PROBE_DEADLINE") != "1" {
		return
	}
	root := os.Getenv("KOGEN_TEST_ROOT")
	requestBytes, err := os.ReadFile(os.Getenv("KOGEN_TEST_PROBE_REQUEST"))
	if err != nil {
		t.Fatal(err)
	}
	var request map[string]any
	if err := json.Unmarshal(requestBytes, &request); err != nil {
		t.Fatal(err)
	}
	if request["type"] != "run" || request["command"] != "shape" || request["install_root"] != root {
		t.Fatal("expected a shape run request for the installed core")
	}
	if problem := checkSeams(); problem != "" {
		t.Fatal(problem)
	}
	s := newSession(root)
	s.core, s.in, s.out = coreCommand(root)
	replies := &probeReplies{WriteCloser: s.in}
	s.in = replies
	ended := false
	t.Cleanup(func() {
		if !ended {
			s.killCore()
		}
		s.killGroups()
	})

	messages := make(chan map[string]any)
	readErrors := make(chan error, 1)
	done := make(chan struct{})
	defer close(done)
	go func() {
		for {
			message, err := s.readMsg()
			if err != nil {
				readErrors <- err
				return
			}
			select {
			case messages <- message:
			case <-done:
				return
			}
		}
	}()
	deadline := time.NewTimer(45 * time.Second)
	defer deadline.Stop()
	next := func() map[string]any {
		select {
		case message := <-messages:
			return message
		case err := <-readErrors:
			t.Fatalf("installed core protocol: %v", err)
		case <-deadline.C:
			t.Fatal("installed probe deadline driver exceeded 45 seconds")
		}
		return nil
	}
	s.send(map[string]any{"type": "hello"})
	if hello := next(); hello["type"] != "hello" {
		t.Fatalf("core did not answer hello: %v", hello)
	}
	s.send(request)

	var probe map[string]any
	for {
		message := next()
		if message["type"] == "exec" && message["timeout_ms"] != nil {
			if probe != nil || message["timeout_ms"] != float64(300000) || message["command"] != "sleep 600" {
				t.Fatalf("expected one hanging probe with the production deadline: %v", message)
			}
			probe = message
			contracted := make(map[string]any, len(message))
			for key, value := range message {
				contracted[key] = value
			}
			contracted["timeout_ms"] = float64(200)
			message = contracted
		}
		code, finished := s.handle(message)
		if !finished {
			continue
		}
		if code != 0 || probe == nil {
			t.Fatalf("shaping exit %d, observed probe %v", code, probe)
		}
		s.endCore()
		ended = true
		break
	}

	// The core has consumed the replies; let any in-flight send finish recording.
	s.sendMu.Lock()
	s.sendMu.Unlock()
	var pgid, status int
	var started, completed, timedOut bool
	for _, message := range replies.snapshot() {
		if message["id"] != probe["id"] {
			continue
		}
		switch message["type"] {
		case "exec_started":
			pgid = int(message["pgid"].(float64))
			started = true
		case "exec_done":
			status = int(message["status"].(float64))
			timedOut, _ = message["timed_out"].(bool)
			completed = true
		}
	}
	if !started || !completed || pgid <= 0 || status == 0 || !timedOut {
		t.Fatalf("expected genuine timed-out process: started=%v completed=%v pgid=%d status=%d timed_out=%v", started, completed, pgid, status, timedOut)
	}
	// Check before driver cleanup, so cleanup cannot hide a broken executor.
	waitForProcessGroupGone(t, pgid, 3*time.Second)
	scratch, _ := probe["cwd"].(string)
	if !filepath.IsAbs(scratch) || !strings.HasPrefix(filepath.Base(scratch), "kogen-probe-") {
		t.Fatalf("probe did not use a scratch folder: %q", scratch)
	}
	if _, err := os.Stat(scratch); !os.IsNotExist(err) {
		t.Fatalf("probe scratch remains: %s (%v)", scratch, err)
	}
	receipt := map[string]any{
		"original_timeout_ms": 300000, "executed_timeout_ms": 200,
		"command": probe["command"], "scratch": scratch, "pgid": pgid,
		"exec_status": status, "timed_out": timedOut,
		"process_group_stopped": true, "scratch_removed": true, "core_exit": 0,
	}
	if err := os.WriteFile(os.Getenv("KOGEN_TEST_PROBE_RECEIPT"), encode(receipt), 0o600); err != nil {
		t.Fatal(err)
	}
}

// Observe only bytes the production executor actually sends to the core.
// Its writer and JSON protocol remain unchanged.
type probeReplies struct {
	io.WriteCloser
	mu       sync.Mutex
	messages []map[string]any
}

func (p *probeReplies) Write(bytes []byte) (int, error) {
	n, err := p.WriteCloser.Write(bytes)
	if err == nil && n == len(bytes) {
		var message map[string]any
		if json.Unmarshal(bytes, &message) == nil {
			p.mu.Lock()
			p.messages = append(p.messages, message)
			p.mu.Unlock()
		}
	}
	return n, err
}

func (p *probeReplies) snapshot() []map[string]any {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]map[string]any(nil), p.messages...)
}

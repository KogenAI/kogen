package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/KogenAI/kogen-loop/api"
	"github.com/KogenAI/kogen-loop/sys"
)

func TestValidateTaskDeadlineSeconds(t *testing.T) {
	root := t.TempDir()
	max := int64(math.MaxInt64) / int64(time.Second)
	cases := []struct {
		name     string
		seconds  int64
		invalid  bool
		overflow bool
	}{
		{"zero", 0, false, false},
		{"negative", -1, true, false},
		{"below maximum", max - 1, false, false},
		{"maximum", max, false, false},
		{"first above maximum", max + 1, true, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if strconv.IntSize == 32 && tc.seconds > math.MaxInt32 {
				t.Skip("deadline cannot be represented by int on this platform")
			}
			got, err := validateTask(api.Task{Root: root, Prompt: "prompt", Role: api.Role{Provider: "chatgpt"}, DeadlineSeconds: int(tc.seconds)})
			if !tc.invalid {
				if err != nil || got != root {
					t.Fatalf("validateTask = %q, %v; want %q, nil", got, err, root)
				}
				return
			}
			e, ok := sys.AsError(err)
			if !ok || e.Class != api.ErrClassLoop || e.Reason != api.ErrInvalidTask || e.Exit != api.ExitInvalid {
				t.Fatalf("validateTask error = %v; want invalid task", err)
			}
			if !strings.Contains(e.Detail, "deadline_seconds") || (tc.overflow && !strings.Contains(e.Detail, fmt.Sprint(tc.seconds))) {
				t.Errorf("invalid task detail = %q", e.Detail)
			}
		})
	}
	t.Run("relative root", func(t *testing.T) {
		want, err := filepath.Abs(".")
		if err != nil {
			t.Fatal(err)
		}
		got, err := validateTask(api.Task{Root: ".", Prompt: "prompt", Role: api.Role{Provider: "chatgpt"}})
		if err != nil || got != want {
			t.Fatalf("validateTask = %q, %v; want %q, nil", got, err, want)
		}
	})
}

func TestReadTaskProtocolRefusalPrecedesFieldDecoding(t *testing.T) {
	cases := []struct {
		name, input, reason string
		detailParts         []string
	}{
		{"foreign protocol", `{"protocol":"kogen-loop/v2","unknown_field":true}`, api.ErrUnsupportedProtocol, []string{"kogen-loop/v2", "kogen-loop/v1"}},
		{"supported protocol", `{"protocol":"kogen-loop/v1","unknown_field":true}`, api.ErrInvalidTask, []string{"unknown_field"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := readTask("-", strings.NewReader(tc.input))
			e, ok := sys.AsError(err)
			if !ok || e.Class != api.ErrClassLoop || e.Exit != api.ExitInvalid || e.Reason != tc.reason {
				t.Fatalf("readTask error = %v; want loop/%s exit 2", err, tc.reason)
			}
			for _, part := range tc.detailParts {
				if !strings.Contains(e.Detail, part) {
					t.Errorf("readTask detail = %q; want %q", e.Detail, part)
				}
			}
		})
	}
}

func TestRunWithoutTaskEndsSessionWithZeroTiming(t *testing.T) {
	var stdout, stderr bytes.Buffer
	exit := run([]string{"run"}, strings.NewReader(""), &stdout, &stderr)
	if exit != api.ExitInvalid {
		t.Errorf("run exit = %d, want invalid-task exit 2", exit)
	}

	if api.ExitInvalid != 2 {
		t.Errorf("invalid-task exit code = %d, want 2", api.ExitInvalid)
	}

	var events []map[string]any
	scanner := bufio.NewScanner(&stdout)
	for scanner.Scan() {
		var event map[string]any
		if err := json.Unmarshal(scanner.Bytes(), &event); err != nil {
			t.Fatalf("invalid JSON event: %v", err)
		}
		events = append(events, event)
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
	if len(events) != 2 {
		t.Fatalf("events = %#v, want error then session.ended; stderr = %s", events, stderr.String())
	}
	if events[0]["type"] != "error" || events[0]["class"] != "loop" || events[0]["reason"] != "invalid_task" {
		t.Errorf("refusal event = %#v", events[0])
	}
	if detail, ok := events[0]["detail"].(string); !ok || !strings.Contains(detail, "run needs --task FILE|-") {
		t.Errorf("refusal detail = %#v", events[0]["detail"])
	}
	ended := events[1]
	if ended["type"] != "session.ended" || ended["status"] != "failed" || ended["exit"] != float64(2) {
		t.Errorf("ended event = %#v", ended)
	}
	wantTiming := map[string]any{
		"wall_ms": float64(0), "provider_wait_ms": float64(0), "backoff_ms": float64(0),
		"tool_wall_ms": float64(0), "overhead_ms": float64(0), "session_wall_ms": float64(0),
		"tool_ms": map[string]any{},
	}
	if !reflect.DeepEqual(ended["timing"], wantTiming) {
		t.Errorf("timing = %#v, want %#v", ended["timing"], wantTiming)
	}
}

func TestRunRefusesUnsupportedRequiredCapabilityBeforeSession(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	task, err := json.Marshal(api.Task{
		Protocol: api.Protocol, Root: t.TempDir(), Prompt: "prompt",
		Role: api.Role{Provider: "chatgpt"}, Requires: []string{"subagents"},
	})
	if err != nil {
		t.Fatal(err)
	}
	var stdout, stderr bytes.Buffer
	exit := run([]string{"run", "--task", "-"}, bytes.NewReader(task), &stdout, &stderr)
	if api.ExitInvalid != 2 {
		t.Errorf("invalid-task exit code = %d, want 2", api.ExitInvalid)
	}
	if exit != api.ExitInvalid {
		t.Errorf("run exit = %d, want invalid-task exit 2", exit)
	}

	var events []map[string]any
	scanner := bufio.NewScanner(&stdout)
	for scanner.Scan() {
		var event map[string]any
		if err := json.Unmarshal(scanner.Bytes(), &event); err != nil {
			t.Fatalf("invalid JSON event: %v", err)
		}
		events = append(events, event)
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
	if len(events) != 2 {
		t.Fatalf("events = %#v, want error then session.ended; stderr = %s", events, stderr.String())
	}
	if events[0]["type"] != "error" || events[0]["class"] != "loop" || events[0]["reason"] != "unsupported_capability" {
		t.Errorf("refusal event = %#v", events[0])
	}
	if detail, ok := events[0]["detail"].(string); !ok || !strings.Contains(detail, `"subagents"`) {
		t.Errorf("refusal detail = %#v, want quoted capability name", events[0]["detail"])
	}
	if events[1]["type"] != "session.ended" || events[1]["status"] != "failed" || events[1]["exit"] != float64(2) {
		t.Errorf("ended event = %#v", events[1])
	}
}

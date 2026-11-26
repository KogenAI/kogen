package main

import (
	"fmt"
	"math"
	"path/filepath"
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

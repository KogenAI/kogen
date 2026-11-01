// Package testproc provides process isolation for tests with process-wide state.
package testproc

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"testing"
	"time"
)

// Isolate schedules the calling test in a child, or applies its environment in that child.
func Isolate(t *testing.T, env ...string) bool {
	t.Helper()
	if _, ok := os.LookupEnv("KOGEN_TESTPROC"); ok {
		for _, entry := range env {
			key, value, _ := strings.Cut(entry, "=")
			old, exists := os.LookupEnv(key)
			if err := os.Setenv(key, value); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() {
				if exists {
					_ = os.Setenv(key, old)
				} else {
					_ = os.Unsetenv(key)
				}
			})
		}
		return true
	}
	t.Parallel()
	parts := strings.Split(t.Name(), "/")
	for i, part := range parts {
		parts[i] = "^" + regexp.QuoteMeta(part) + "$"
	}
	args := []string{"-test.run=" + strings.Join(parts, "/"), "-test.v", "-test.count=1", "-test.parallel=1"}
	ctx := context.Background()
	if deadline, ok := t.Deadline(); ok {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			t.Fatal("testproc: deadline expired")
		}
		// Reserve time before the parent deadline to reap the child and report its result.
		remaining -= remaining / 20
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, remaining)
		defer cancel()
		args = append(args, "-test.timeout="+remaining.String())
	}
	cmd := exec.CommandContext(ctx, os.Args[0], args...)
	cmd.Env = append(os.Environ(), "KOGEN_TESTPROC="+t.Name())
	var output bytes.Buffer
	cmd.Stdout, cmd.Stderr = &output, &output
	err := cmd.Run()
	text := output.String()
	result := func(status string) bool {
		prefix := fmt.Sprintf("--- %s: %s (", status, t.Name())
		for _, line := range strings.Split(text, "\n") {
			if strings.HasPrefix(strings.TrimLeft(line, " \t"), prefix) {
				return true
			}
		}
		return false
	}
	if err != nil {
		t.Fatalf("testproc: child failed: %v\n%s", err, text)
	}
	if result("SKIP") {
		t.Skip(text)
	}
	if !result("PASS") {
		t.Fatalf("testproc: child missing result for %s\n%s", t.Name(), text)
	}
	return false
}

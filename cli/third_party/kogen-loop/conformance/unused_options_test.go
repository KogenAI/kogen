package conformance

import (
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"testing"

	"kogen-loop/loop"
	"kogen-loop/provider"
)

// The five unused options are removed, not deprecated: no field, interface or constant is left
// for a caller to use, and the retained cache identities are untouched.
func TestUnusedOptionsRemoved(t *testing.T) {
	for _, c := range []struct {
		typ   reflect.Type
		field string
	}{
		{reflect.TypeOf(provider.Request{}), "AnthropicCacheTTL"},
		{reflect.TypeOf(provider.Request{}), "Budget"},
		{reflect.TypeOf(loop.Direct{}), "Policy"},
		{reflect.TypeOf(loop.Round{}), "StopAfterTerminal"},
		{reflect.TypeOf(loop.SessionConfig{}), "CacheID"},
	} {
		if _, ok := c.typ.FieldByName(c.field); ok {
			t.Errorf("%s.%s still exists", c.typ, c.field)
		}
	}
	for _, c := range []struct {
		typ   reflect.Type
		field string
	}{
		{reflect.TypeOf(provider.Request{}), "CacheID"},
		{reflect.TypeOf(loop.Direct{}), "CacheID"},
		{reflect.TypeOf(loop.Direct{}), "InputBudgetBytes"},
		{reflect.TypeOf(provider.Client{}), "ResponseBudget"},
	} {
		if _, ok := c.typ.FieldByName(c.field); !ok {
			t.Errorf("%s.%s must remain", c.typ, c.field)
		}
	}

	root, err := filepath.Abs("..")
	if err != nil {
		t.Fatal(err)
	}
	goMod, err := os.ReadFile(filepath.Join(root, "go.mod"))
	if err != nil {
		t.Fatal(err)
	}
	goVersion := regexp.MustCompile(`(?m)^go (\S+)$`).FindSubmatch(goMod)
	if goVersion == nil {
		t.Fatal("no go directive in go.mod")
	}

	// build compiles one caller in its own temporary module that replaces kogen-loop with this tree.
	build := func(t *testing.T, source string) (string, error) {
		t.Helper()
		dir := t.TempDir()
		module := "module probe\n\ngo " + string(goVersion[1]) + "\n\nrequire kogen-loop v0.0.0\n\nreplace kogen-loop => " + root + "\n"
		for name, content := range map[string]string{"go.mod": module, "main.go": source} {
			if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o600); err != nil {
				t.Fatal(err)
			}
		}
		cmd := exec.Command("go", "build", "-o", os.DevNull, ".")
		cmd.Dir = dir
		cmd.Env = append(os.Environ(), "GOFLAGS=-mod=mod", "GOPROXY=off", "GOTOOLCHAIN=local", "GOWORK=off")
		out, err := cmd.CombinedOutput()
		return string(out), err
	}
	program := func(body string) string {
		return "package main\n\nimport (\n\t\"kogen-loop/loop\"\n\t\"kogen-loop/provider\"\n)\n\n" +
			"var _ = provider.Request{CacheID: \"id\"}\n" +
			"var _ = loop.Direct{CacheID: \"id\", InputBudgetBytes: 65536}\n" +
			"var _ = loop.Round{Terminal: []string{\"finish\"}}\n" +
			"var _ = loop.SessionConfig{Root: \".\"}\n" +
			"var _ = loop.FailOverBudget{}\n" + body + "\nfunc main() {}\n"
	}

	if out, err := build(t, program("")); err != nil {
		t.Fatalf("a caller using only the surviving API must build: %v\n%s", err, out)
	}
	for _, c := range []struct{ member, body string }{
		{"AnthropicCacheTTL", "var _ = provider.Request{AnthropicCacheTTL: \"1h\"}"},
		{"Budget", "var _ = provider.Request{Budget: 1}"},
		{"CacheTTLHour", "var _ = provider.CacheTTLHour"},
		{"Policy", "var _ = loop.Direct{Policy: nil}"},
		{"ContextPolicy", "var _ loop.ContextPolicy"},
		{"StopAfterTerminal", "var _ = loop.Round{StopAfterTerminal: true}"},
		{"SkippedAfterTerminal", "var _ = loop.SkippedAfterTerminal"},
		{"CacheID", "var _ = loop.SessionConfig{CacheID: \"id\"}"},
	} {
		t.Run(c.member, func(t *testing.T) {
			out, err := build(t, program(c.body))
			if err == nil {
				t.Fatalf("%s still compiles", c.member)
			}
			if !strings.Contains(out, c.member) || !strings.Contains(out, "main.go") {
				t.Fatalf("build failed without naming %s:\n%s", c.member, out)
			}
		})
	}
}

package claudecode

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestNewerComparesNumbers(t *testing.T) {
	for _, c := range []struct {
		a, b string
		want bool
	}{
		{"2.1.319", "2.1.318", true},
		{"2.1.318", "2.1.318", false},
		{"2.1.317", "2.1.318", false},
		{"2.1.1000", "2.1.318", true},
		{"2.2.0", "2.1.999", true},
		{"3.0.0", "2.9.9", true},
		{"2.1.319-beta", "2.1.318", false},
		{"latest", "2.1.318", false},
	} {
		if got := newer(c.a, c.b); got != c.want {
			t.Errorf("newer(%q, %q) = %v, want %v", c.a, c.b, got, c.want)
		}
	}
}

func TestHarnessDueAfterADay(t *testing.T) {
	now := time.Date(2026, 11, 19, 12, 0, 0, 0, time.UTC)
	at := func(age time.Duration) Harness { return Harness{CheckedAt: now.Add(-age).Format(time.RFC3339)} }
	for _, c := range []struct {
		name string
		h    Harness
		want bool
	}{
		{"missing", Harness{}, true},
		{"unreadable", Harness{CheckedAt: "yesterday"}, true},
		{"23 hours", at(23 * time.Hour), false},
		{"exactly 24 hours", at(24 * time.Hour), false},
		{"25 hours", at(25 * time.Hour), true},
	} {
		if got := c.h.due(now); got != c.want {
			t.Errorf("%s: due = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestActiveFollowsTheFileOnlyForNewerInstalledVersions(t *testing.T) {
	home := t.TempDir()
	root := Root(home)
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	install := func(version string) string {
		p := refFor(home, version).path
		if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("#!/bin/sh\n"), 0o755); err != nil {
			t.Fatal(err)
		}
		return p
	}
	activate := func(text string) {
		if err := os.WriteFile(filepath.Join(root, ActiveFile), []byte(text), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	expect := func(name, version, path string) {
		t.Helper()
		if v, p := Active(home); v != version || p != path {
			t.Errorf("%s: Active = %s %s, want %s %s", name, v, p, version, path)
		}
	}
	pin := RuntimePath(home)
	expect("no active file", Version, pin)
	activate("2.1.319\n")
	expect("active folder not installed", Version, pin)
	newer := install("2.1.319")
	expect("active installed", "2.1.319", newer)
	activate("2.1.100\n")
	install("2.1.100")
	expect("active older than the pin", Version, pin)
	activate("not a version\n")
	expect("unreadable active file", Version, pin)
	activate(Version + "\n")
	expect("active names the pin", Version, pin)
}

func TestJudgeNamesTheFailingCheck(t *testing.T) {
	calls := scriptedCalls("/checkout")
	ok := map[string]toolResult{calls[0].id: {}, calls[1].id: {}, calls[2].id: {isError: true}}
	rec := func(id, decision string) sentinel {
		return sentinel{Hook: "pretool", ToolUseID: id, Decision: decision}
	}
	allRecords := map[string]sentinel{calls[0].id: rec(calls[0].id, "allow"), calls[1].id: rec(calls[1].id, "allow"), calls[2].id: rec(calls[2].id, "deny")}
	write := func(root, name, content string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(root, name), []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	checkout := func(protected string) string {
		root := t.TempDir()
		write(root, newFileName, newFileContent)
		write(root, existingFileName, existingEdited)
		write(root, protectedFileName, protected)
		return root
	}
	without := func(m map[string]sentinel, id string) map[string]sentinel {
		out := map[string]sentinel{}
		for k, v := range m {
			if k != id {
				out[k] = v
			}
		}
		return out
	}
	denyAsAllow := map[string]sentinel{calls[0].id: allRecords[calls[0].id], calls[1].id: allRecords[calls[1].id], calls[2].id: rec(calls[2].id, "allow")}
	protectedWritten := map[string]toolResult{calls[0].id: {}, calls[1].id: {}, calls[2].id: {}}

	for _, c := range []struct {
		name    string
		root    string
		results map[string]toolResult
		records map[string]sentinel
		want    string
	}{
		{"works", checkout(protectedOriginal), ok, allRecords, ""},
		{"hook never ran", checkout("overwritten\n"), protectedWritten, map[string]sentinel{}, checkNoHookRecord},
		{"one write without a record", checkout(protectedOriginal), ok, without(allRecords, calls[1].id), checkNoHookRecord},
		{"hook ran but the protected write happened", checkout("overwritten\n"), protectedWritten, allRecords, checkProtectedPass},
		{"protected write allowed by the hook", checkout(protectedOriginal), ok, denyAsAllow, checkProtectedPass},
		{"protected call not reported as an error", checkout(protectedOriginal), protectedWritten, allRecords, checkProtectedPass},
		{"new file not written", func() string { r := checkout(protectedOriginal); os.Remove(filepath.Join(r, newFileName)); return r }(), ok, allRecords, checkWriteMissing},
	} {
		if got := judge(c.root, calls, c.results, c.records, false); got != c.want {
			t.Errorf("%s: judge = %q, want %q", c.name, got, c.want)
		}
	}
}

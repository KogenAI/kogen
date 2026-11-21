package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// The docs that packaging/package.sh copies into the release archive are named a second time in
// the SHIPPED_DOCS tuple of the archive mode observer. These tests fail when the two lists differ,
// or when a copied name has no file in the docs folder.

const (
	docsScriptPath   = "../packaging/package.sh"
	docsObserverPath = "../features/steps/release_archive_public_modes.py"
	docsFolderPath   = "../docs"
)

var (
	docsCopyLine   = regexp.MustCompile(`\bcp((?: docs/\S+)+) "\$work/docs/"`)
	docsTupleStart = regexp.MustCompile(`(?m)^SHIPPED_DOCS = \(([^)]*)\)`)
	docsQuotedName = regexp.MustCompile(`['"]([^'"]+)['"]`)
)

// docsListFaults returns one line per fault; none means the lists agree and every copied doc exists.
func docsListFaults(script, observer, docsDir string) []string {
	var copyLines []string
	for _, line := range strings.Split(script, "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), "#") {
			continue
		}
		if m := docsCopyLine.FindStringSubmatch(line); m != nil {
			copyLines = append(copyLines, m[1])
		}
	}
	tuple := docsTupleStart.FindStringSubmatch(observer)

	var faults []string
	switch {
	case len(copyLines) == 0:
		faults = append(faults, "script has no docs copy line")
	case len(copyLines) != 1:
		faults = append(faults, fmt.Sprintf("script has %d docs copy lines, want exactly 1", len(copyLines)))
	}
	if tuple == nil {
		faults = append(faults, "observer has no SHIPPED_DOCS tuple")
	}
	if len(faults) > 0 {
		return faults
	}

	scriptNames := map[string]bool{}
	for _, f := range strings.Fields(copyLines[0]) {
		scriptNames[strings.TrimPrefix(f, "docs/")] = true
	}
	observerNames := map[string]bool{}
	for _, m := range docsQuotedName.FindAllStringSubmatch(tuple[1], -1) {
		observerNames[m[1]] = true
	}

	for _, name := range sortedNames(observerNames) {
		if !scriptNames[name] {
			faults = append(faults, name+": script lacks it")
		}
	}
	for _, name := range sortedNames(scriptNames) {
		if !observerNames[name] {
			faults = append(faults, name+": observer lacks it")
		}
		if info, err := os.Stat(filepath.Join(docsDir, name)); err != nil || !info.Mode().IsRegular() {
			faults = append(faults, name+": docs folder has no such file")
		}
	}
	return faults
}

func sortedNames(set map[string]bool) []string {
	names := make([]string, 0, len(set))
	for name := range set {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

func TestPackageDocsListMatchesObserverOnRealTree(t *testing.T) {
	script, err := os.ReadFile(docsScriptPath)
	if err != nil {
		t.Fatal(err)
	}
	observer, err := os.ReadFile(docsObserverPath)
	if err != nil {
		t.Fatal(err)
	}
	for _, fault := range docsListFaults(string(script), string(observer), docsFolderPath) {
		t.Error(fault)
	}
}

func TestPackageDocsListFixtures(t *testing.T) {
	scriptWith := func(names ...string) string {
		return "set -e\n# cp docs/commented.md \"$work/docs/\"\nmkdir -p \"$work/docs\" && cp docs/" +
			strings.Join(names, " docs/") + " \"$work/docs/\"\n"
	}
	observerWith := func(names ...string) string {
		return "X = ('x.md',)\nSHIPPED_DOCS = ('" + strings.Join(names, "', '") + "')\n"
	}
	docsDir := t.TempDir()
	for _, name := range []string{"a.md", "b.md", "c.md"} {
		if err := os.WriteFile(filepath.Join(docsDir, name), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	twoCopies := scriptWith("a.md") + scriptWith("a.md")

	cases := []struct {
		name             string
		script, observer string
		want             []string
	}{
		{"same lists", scriptWith("a.md", "b.md"), observerWith("a.md", "b.md"), nil},
		{"order and duplicates ignored", scriptWith("b.md", "a.md", "b.md"), observerWith("a.md", "b.md", "a.md"), nil},
		{"observer lacks", scriptWith("a.md", "b.md"), observerWith("a.md"), []string{"b.md: observer lacks it"}},
		{"script lacks", scriptWith("a.md"), observerWith("a.md", "c.md"), []string{"c.md: script lacks it"}},
		{"rename keeps counts", scriptWith("a.md", "b.md"), observerWith("a.md", "c.md"),
			[]string{"c.md: script lacks it", "b.md: observer lacks it"}},
		{"copied name without a file", scriptWith("a.md", "gone.md"), observerWith("a.md", "gone.md"),
			[]string{"gone.md: docs folder has no such file"}},
		{"no copy line", "set -e\n# cp docs/a.md \"$work/docs/\"\n", observerWith("a.md"), []string{"script has no docs copy line"}},
		{"two copy lines", twoCopies, observerWith("a.md"), []string{"script has 2 docs copy lines, want exactly 1"}},
		{"no tuple", scriptWith("a.md"), "OTHER = ('a.md',)\n", []string{"observer has no SHIPPED_DOCS tuple"}},
		{"structural faults hide name comparison", "set -e\n", "OTHER = ()\n",
			[]string{"script has no docs copy line", "observer has no SHIPPED_DOCS tuple"}},
	}
	for _, c := range cases {
		got := docsListFaults(c.script, c.observer, docsDir)
		if strings.Join(got, "\n") != strings.Join(c.want, "\n") {
			t.Errorf("%s: faults %q, want %q", c.name, got, c.want)
		}
	}
}

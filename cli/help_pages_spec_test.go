package main

import (
	"fmt"
	"os"
	"strings"
	"testing"
)

// The printed help pages exist in three hand-kept copies: the program, the fenced blocks under
// CLI-3 of chapter 09, and the byte-exact constants of the acceptance handlers. These tests fail
// when a page differs by one byte between the program and either document.

const (
	chapter09Path = "../spec/prose/09-cli-and-process.md"
	handlersPath  = "../test/acceptance/support/handlers.js"
)

// helpPage names one printed page, its label line in chapter 09 and its constant in handlers.js.
type helpPage struct {
	name, label, constant string
}

var helpPageList = []helpPage{
	{"top", "`kogen`, `kogen help`:", "topHelp"},
	{"intent", "`kogen intent`:", "intentHelp"},
	{"provider", "`kogen provider`:", "providerHelp"},
}

// printedHelpPages returns the pages as the program's own help path prints them.
func printedHelpPages() map[string]string {
	return map[string]string{
		"top":      pageOf(parse(nil)),
		"intent":   pageOf(parse([]string{"intent"})),
		"provider": pageOf(parse([]string{"provider"})),
	}
}

func pageOf(_ *invocation, page string, _ *usageError) string { return page }

// chapterBlock returns the fenced block directly after the page's label line, byte for byte from
// the line after the opening fence up to the closing fence.
func chapterBlock(chapter string, p helpPage) (string, error) {
	opening := "\n" + p.label + "\n```\n"
	text := "\n" + chapter
	n := strings.Count(text, opening)
	if n == 0 {
		return "", fmt.Errorf("page %s: no block labelled %s in chapter 09", p.name, p.label)
	}
	if n > 1 {
		return "", fmt.Errorf("page %s: %d blocks labelled %s in chapter 09, want exactly one", p.name, n, p.label)
	}
	rest := text[strings.Index(text, opening)+len(opening):]
	end := strings.Index(rest, "```")
	if end < 0 {
		return "", fmt.Errorf("page %s: the block labelled %s in chapter 09 has no closing fence", p.name, p.label)
	}
	return rest[:end], nil
}

// handlersConstant returns the template literal of the page's constant with the two-character
// escape backslash n decoded to a line feed.
func handlersConstant(js string, p helpPage) (string, error) {
	opening := "const " + p.constant + " = `"
	n := strings.Count(js, opening)
	if n == 0 {
		return "", fmt.Errorf("page %s: no constant %s in handlers.js", p.name, p.constant)
	}
	if n > 1 {
		return "", fmt.Errorf("page %s: %d constants %s in handlers.js, want exactly one", p.name, n, p.constant)
	}
	rest := js[strings.Index(js, opening)+len(opening):]
	end := strings.Index(rest, "`")
	if end < 0 {
		return "", fmt.Errorf("page %s: the constant %s in handlers.js has no closing backtick", p.name, p.constant)
	}
	return strings.ReplaceAll(rest[:end], `\n`, "\n"), nil
}

// firstDifference returns "" when the texts are equal, otherwise a message quoting the first
// differing line of each side. Lines keep their line end, so a missing final LF is a difference.
func firstDifference(printed, other string) string {
	if printed == other {
		return ""
	}
	a, b := strings.SplitAfter(printed, "\n"), strings.SplitAfter(other, "\n")
	for i := 0; ; i++ {
		switch {
		case i >= len(a) && i >= len(b):
			return ""
		case i >= len(a):
			return fmt.Sprintf("line %d: printed page has no more lines, document has %q", i+1, b[i])
		case i >= len(b):
			return fmt.Sprintf("line %d: printed page has %q, document has no more lines", i+1, a[i])
		case a[i] != b[i]:
			return fmt.Sprintf("line %d: printed page has %q, document has %q", i+1, a[i], b[i])
		}
	}
}

// helpPageErrors compares every printed page with its chapter 09 block and its handlers.js
// constant and returns one error per difference, missing or duplicated page.
func helpPageErrors(printed map[string]string, chapter, handlers string) []error {
	var errs []error
	for _, p := range helpPageList {
		if block, err := chapterBlock(chapter, p); err != nil {
			errs = append(errs, err)
		} else if d := firstDifference(printed[p.name], block); d != "" {
			errs = append(errs, fmt.Errorf("page %s differs from chapter 09: %s", p.name, d))
		}
		if value, err := handlersConstant(handlers, p); err != nil {
			errs = append(errs, err)
		} else if d := firstDifference(printed[p.name], value); d != "" {
			errs = append(errs, fmt.Errorf("page %s differs from %s in handlers.js: %s", p.name, p.constant, d))
		}
	}
	return errs
}

func joinErrors(errs []error) string {
	var parts []string
	for _, e := range errs {
		parts = append(parts, e.Error())
	}
	return strings.Join(parts, "\n")
}

// wantOneError requires exactly one error whose text contains every part.
func wantOneError(t *testing.T, errs []error, parts ...string) {
	t.Helper()
	if len(errs) != 1 {
		t.Fatalf("got %d errors, want exactly 1:\n%s", len(errs), joinErrors(errs))
	}
	for _, part := range parts {
		if !strings.Contains(errs[0].Error(), part) {
			t.Errorf("error %q lacks %q", errs[0].Error(), part)
		}
	}
}

// The fixtures are built from the printed pages, so they stay equal to them until one is changed.
func fixtureChapter(printed map[string]string, only ...string) string {
	var b strings.Builder
	b.WriteString("**CLI-3 — Help pages.** Byte-exact.\n\n")
	for _, p := range helpPageList {
		if len(only) > 0 && !contains(only, p.name) {
			continue
		}
		b.WriteString(p.label + "\n```\n" + printed[p.name] + "```\n\n")
	}
	return b.String()
}

func fixtureHandlers(printed map[string]string) string {
	var b strings.Builder
	for _, p := range helpPageList {
		b.WriteString("const " + p.constant + " = `" + strings.ReplaceAll(printed[p.name], "\n", `\n`) + "`;\n")
	}
	return b.String()
}

const providerLoginLine = "  login                    On an interactive terminal, ask which account to use and guide the sign-in\n"

func TestPrintedHelpPagesMatchChapter09AndHandlers(t *testing.T) {
	chapter, err := os.ReadFile(chapter09Path)
	if err != nil {
		t.Fatal(err)
	}
	handlers, err := os.ReadFile(handlersPath)
	if err != nil {
		t.Fatal(err)
	}
	for _, err := range helpPageErrors(printedHelpPages(), string(chapter), string(handlers)) {
		t.Error(err)
	}
}

func TestHelpPageComparisonRejectsDriftInEitherDocument(t *testing.T) {
	printed := printedHelpPages()
	chapter, handlers := fixtureChapter(printed), fixtureHandlers(printed)
	if errs := helpPageErrors(printed, chapter, handlers); len(errs) != 0 {
		t.Fatalf("fixtures built from the printed pages are rejected:\n%s", joinErrors(errs))
	}
	if !strings.Contains(printed["provider"], providerLoginLine) {
		t.Fatalf("the printed provider page lacks the login line %q", providerLoginLine)
	}

	loginText := strings.TrimSuffix(providerLoginLine, "\n")
	drifted := strings.Replace(chapter, providerLoginLine, "", 1)
	wantOneError(t, helpPageErrors(printed, drifted, handlers), "page provider", "chapter 09", loginText)

	escaped := strings.ReplaceAll(providerLoginLine, "\n", `\n`)
	drifted = strings.Replace(handlers, escaped, "", 1)
	wantOneError(t, helpPageErrors(printed, chapter, drifted), "page provider", "providerHelp", loginText)

	// One space at the end of a line of the intent page is drift too.
	preflight := "  preflight <slug>         Observe read-only prerequisites\n"
	drifted = strings.Replace(chapter, preflight, strings.TrimSuffix(preflight, "\n")+" \n", 1)
	wantOneError(t, helpPageErrors(printed, drifted, handlers), "page intent", "chapter 09", "prerequisites \\n")
}

func TestHelpPageComparisonRejectsMissingAndDuplicateBlocks(t *testing.T) {
	printed := printedHelpPages()
	handlers := fixtureHandlers(printed)

	wantOneError(t, helpPageErrors(printed, fixtureChapter(printed, "top", "provider"), handlers), "page intent", "chapter 09")

	twice := fixtureChapter(printed) + fixtureChapter(printed, "provider")
	wantOneError(t, helpPageErrors(printed, twice, handlers), "page provider", "chapter 09")

	wantOneError(t, helpPageErrors(printed, fixtureChapter(printed), strings.Replace(handlers, "const intentHelp = ", "const intentHelpGone = ", 1)), "page intent", "intentHelp")
}

func TestHelpPageComparisonRejectsMissingFinalLineEnd(t *testing.T) {
	printed := printedHelpPages()
	handlers := fixtureHandlers(printed)
	chapter := fixtureChapter(printed)
	block := "provider`:\n```\n" + printed["provider"] + "```\n"
	if !strings.Contains(chapter, block) {
		t.Fatal("fixture lacks the provider block")
	}
	short := strings.Replace(chapter, block, "provider`:\n```\n"+strings.TrimSuffix(printed["provider"], "\n")+"```\n", 1)
	wantOneError(t, helpPageErrors(printed, short, handlers), "page provider", "chapter 09", `Logins belong to this machine, never to a repo.\n"`)
}

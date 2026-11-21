package main

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

const qwenLabel = "experimental: Build verified with Claude Review; Shape and Review not qualified"

// acceptedProviderNames reads the names from the unknown-provider message in main.go, since no exported list exists.
func acceptedProviderNames(t *testing.T) []string {
	t.Helper()
	source, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	m := regexp.MustCompile(`unknown provider '%s' \(supported: ([a-z, -]+)\)`).FindSubmatch(source)
	if m == nil {
		t.Fatal("main.go has no unknown-provider message listing the accepted names")
	}
	var names []string
	for _, name := range strings.Split(string(m[1]), ",") {
		names = append(names, strings.TrimSpace(name))
	}
	return names
}

func tableCells(line string) []string {
	line = strings.TrimSuffix(strings.TrimPrefix(strings.TrimSpace(line), "|"), "|")
	cells := strings.Split(line, "|")
	for i := range cells {
		cells[i] = strings.TrimSpace(cells[i])
	}
	return cells
}

// providerRows returns the table rows keyed by provider name, in a page's one comparison table.
func providerRows(page string) map[string][]string {
	rows := map[string][]string{}
	for _, line := range strings.Split(page, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "|") || !strings.HasSuffix(line, "|") {
			continue
		}
		cells := tableCells(line)
		name := strings.ReplaceAll(cells[0], "`", "")
		if name == "Provider" || strings.Trim(name, "-: ") == "" {
			continue
		}
		rows[name] = cells
	}
	return rows
}

var recordPath = regexp.MustCompile("`([^`]+)`")

// rolesProblem returns a description of the first role that is neither "not qualified" nor "verified"
// with an existing qualification record, or "" when every role is acceptable.
func rolesProblem(provider, cell string) string {
	for _, entry := range strings.Split(cell, ";") {
		role, status, ok := strings.Cut(strings.TrimSpace(entry), ": ")
		if !ok {
			return provider + ": roles entry " + entry + " is not 'Role: status'"
		}
		if status == "not qualified" {
			continue
		}
		if !strings.HasPrefix(status, "verified") {
			return provider + " " + role + ": status " + status + " is neither not qualified nor verified"
		}
		paths := recordPath.FindAllStringSubmatch(status, -1)
		if len(paths) == 0 {
			return provider + " " + role + " is verified without a qualification record path"
		}
		for _, p := range paths {
			info, err := os.Stat("../" + p[1])
			if err != nil || !info.Mode().IsRegular() {
				return provider + " " + role + " is verified by " + p[1] + ", which does not exist"
			}
		}
	}
	return ""
}

func guideProblem(page string, names []string) string {
	rows := providerRows(page)
	for _, name := range names {
		row, ok := rows[name]
		if !ok {
			return "the comparison table has no row for provider " + name
		}
		if len(row) != 5 {
			return "the row of " + name + " does not have five columns"
		}
		if problem := rolesProblem(name, row[2]); problem != "" {
			return problem
		}
	}
	return ""
}

func readProvidersGuide(t *testing.T) string {
	t.Helper()
	page, err := os.ReadFile("../docs/providers.md")
	if err != nil {
		t.Fatal(err)
	}
	return string(page)
}

func TestProvidersGuideHasARowForEveryAcceptedProvider(t *testing.T) {
	names := acceptedProviderNames(t)
	if len(names) == 0 {
		t.Fatal("no accepted provider names")
	}
	if problem := guideProblem(readProvidersGuide(t), names); problem != "" {
		t.Error(problem)
	}
}

func TestProvidersGuideRejectsAMissingRowAndAMissingRecord(t *testing.T) {
	head := "| Provider | Account or key needed | Roles verified | Built in or custom endpoint | Setup |\n| --- | --- | --- | --- | --- |\n"
	good := head + "| `chatgpt` | account | Shape: verified (`spec/reference/model-family-qualification.md`); Build: not qualified; Review: not qualified | Built in | [Sign in](getting-started.md) |\n"
	if problem := guideProblem(good, []string{"chatgpt"}); problem != "" {
		t.Errorf("an existing record was rejected: %s", problem)
	}
	missing := strings.ReplaceAll(good, "model-family-qualification.md", "no-such-record.md")
	if guideProblem(missing, []string{"chatgpt"}) == "" {
		t.Error("a verified role with a missing record was accepted")
	}
	if guideProblem(good, []string{"chatgpt", "supergrok"}) == "" {
		t.Error("a table without a row for supergrok was accepted")
	}
}

func TestProvidersGuideKeepsTheQwenCloudFacts(t *testing.T) {
	page := readProvidersGuide(t)
	for _, want := range []string{
		qwenLabel,
		"https://token-plan.maas.qwencloudapi.com/compatible-mode/v1",
		"https://ap-southeast-1.maas.qwencloudapi.com/compatible-mode/v1",
		"kogen provider login openai-compatible",
		"build: {provider: openai-compatible, base_url: https://token-plan.maas.qwencloudapi.com/compatible-mode/v1, model: qwen4-max, effort: high}",
		"Token Plan terms",
		"pay-as-you-go",
		"does not yet stream",
	} {
		if !strings.Contains(page, want) {
			t.Errorf("docs/providers.md does not contain: %s", want)
		}
	}
	if strings.Contains(strings.ToLower(page), "messages-compatible") {
		t.Error("docs/providers.md mentions messages-compatible")
	}
}

func TestProvidersGuideSaysTheQwenCloudBuildEvidenceCameViaTheFleetProxy(t *testing.T) {
	page := readProvidersGuide(t)
	start := strings.Index(page, "### QwenCloud\n")
	if start < 0 {
		t.Fatal("docs/providers.md has no QwenCloud section")
	}
	section := page[start:]
	lines := strings.Split(section, "\n")
	label, fence := -1, -1
	for i, line := range lines {
		if line == qwenLabel && label < 0 {
			label = i
		}
		if strings.HasPrefix(line, "```") && fence < 0 {
			fence = i
		}
	}
	if label < 0 || fence <= label {
		t.Fatal("the QwenCloud section needs the label line before its setup example")
	}
	var between []string
	for _, line := range lines[label+1 : fence] {
		if strings.TrimSpace(line) != "" {
			between = append(between, line)
		}
	}
	if len(between) == 0 || !strings.Contains(between[0], "fleet proxy") {
		t.Fatalf("the line directly after the label line does not name the fleet proxy: %q", between)
	}
	sentence := between[0]
	for _, want := range []string{"direct public-install Build", "still under test"} {
		if !strings.Contains(sentence, want) {
			t.Errorf("the fleet proxy sentence does not contain %q: %s", want, sentence)
		}
	}
	if n := strings.Count(strings.ToLower(page), "fleet proxy"); n != 1 {
		t.Errorf("docs/providers.md names the fleet proxy %d times, want once", n)
	}
}

package main

import (
	"encoding/json"
	"fmt"
	"kogen/internal/testrelease"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func TestUsageLimitResumeInstalledRound2(t *testing.T) { usageLimitInstalled(t, 2) }
func TestUsageLimitResumeInstalledRound3(t *testing.T) { usageLimitInstalled(t, 3) }

// Synthetic rate_limit events reproduce the historical error envelope, not a live account.
func usageLimitInstalled(t *testing.T, limit int) {
	usageLimitInstalledFrom(t, limit, repoRoot(t))
}
func usageLimitInstalledFrom(t *testing.T, limit int, root string) {
	archive := testrelease.Package(t, root, "--version", fmt.Sprintf("usage-limit-round%d", limit))
	unpack := t.TempDir()
	cmd := exec.Command("tar", "-xzf", archive, "-C", unpack)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("extract: %v %s", err, out)
	}
	entries, err := os.ReadDir(unpack)
	if err != nil || len(entries) != 1 {
		t.Fatalf("archive: %v %v", entries, err)
	}
	prefix := filepath.Join(t.TempDir(), "install")
	cmd = exec.Command("sh", filepath.Join(unpack, entries[0].Name(), "install.sh"), "--prefix", prefix)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("install: %v %s", err, out)
	}
	bin := filepath.Join(prefix, "bin", "kogen")
	project := t.TempDir()
	home := t.TempDir()
	state := t.TempDir()
	fakebin := t.TempDir()
	copyFile := func(from, to string, mode os.FileMode) {
		t.Helper()
		b, err := os.ReadFile(from)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.MkdirAll(filepath.Dir(to), 0755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(to, b, mode); err != nil {
			t.Fatal(err)
		}
	}
	fixture := filepath.Join(root, "cli/build/testdata/legacy/project")
	err = filepath.Walk(fixture, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if !info.IsDir() {
			rel, _ := filepath.Rel(fixture, path)
			copyFile(path, filepath.Join(project, rel), info.Mode())
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	write := func(path, text string, mode os.FileMode) {
		t.Helper()
		p := filepath.Join(project, path)
		if err := os.MkdirAll(filepath.Dir(p), 0755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(text), mode); err != nil {
			t.Fatal(err)
		}
	}
	cfg := `version: 1
commands:
  setup:
    - 'true'
  fix:
    - 'true'
  checks:
    - name: unit
      run: 'test -f app.txt'
  acceptance:
    run: 'sh accept.sh'
    steps_dir: 'features/steps'
protect:
  - 'accept.sh'
models:
  shape:
    model: gpt-6.1-sol
    effort: high
  build:
    executor: claude-code
    model: claude-sonnet-5-5
    effort: high
  review:
    executor: claude-code
    model: claude-sonnet-5-5
    effort: high
`
	write(".kogen/project.yaml", cfg, 0644)
	write("accept.sh", "#!/bin/sh\nif grep -qx red app.txt; then echo synthetic-red; exit 1; fi\ncp reports/green.ndjson \"$KOGEN_ACCEPTANCE_REPORT\"\n", 0755)
	write("app.txt", "baseline\n", 0644)
	script := filepath.Join(state, "script.json")
	rounds := []any{}
	for i := 1; i < limit; i++ {
		rounds = append(rounds, map[string]any{"actions": []any{map[string]any{"write": map[string]any{"path": "app.txt", "content": "red\n"}}, map[string]any{"write": map[string]any{"path": fmt.Sprintf("marker%d.txt", i), "content": "complete\n"}}}})
	}
	rounds = append(rounds, map[string]any{"end": "synthetic_usage_limit", "actions": []any{map[string]any{"write": map[string]any{"path": "partial.txt", "content": "partial\n"}}}})
	rounds = append(rounds, map[string]any{"actions": []any{map[string]any{"write": map[string]any{"path": "app.txt", "content": "repaired\n"}}}})
	b, _ := json.Marshal(map[string]any{"roles": map[string]any{"build": map[string]any{"rounds": rounds}, "review": map[string]any{"rounds": []any{map[string]any{"structured": map[string]any{"verdict": "approve", "findings": []any{}}}}}}})
	if err := os.WriteFile(script, b, 0644); err != nil {
		t.Fatal(err)
	}
	fake := filepath.Join(root, "test/acceptance/fixtures/claude/fake-claude.js")
	node, err := exec.LookPath("node")
	if err != nil {
		t.Fatal(err)
	}
	shim := fmt.Sprintf("#!/bin/sh\nKOGEN_FAKE_CLAUDE_SCRIPT='%s' KOGEN_FAKE_CLAUDE_STATE='%s' exec '%s' '%s' \"$@\"\n", script, state, node, fake)
	if err := os.WriteFile(filepath.Join(fakebin, "claude"), []byte(shim), 0755); err != nil {
		t.Fatal(err)
	}
	env := isolatedGit(home, "PATH="+fakebin+string(os.PathListSeparator)+os.Getenv("PATH"), "KOGEN_FAKE_CLAUDE_SCRIPT="+script, "KOGEN_FAKE_CLAUDE_STATE="+state)
	run := func(name string, args ...string) (string, int) { return runIn(t, project, env, name, args...) }
	for _, args := range [][]string{{"init", "-q"}, {"config", "user.name", "Fixture"}, {"config", "user.email", "fixture@example.invalid"}, {"add", "."}, {"commit", "-qm", "fixture"}} {
		if out, code := run("git", args...); code != 0 {
			t.Fatalf("git %v: %s", args, out)
		}
	}
	start, _ := run("git", "rev-parse", "HEAD")
	start = strings.TrimSpace(start)
	card, code := run(bin, "intent", "approve", "fixture")
	hash := regexp.MustCompile(`\b[0-9a-f]{64}\b`).FindString(card)
	if code != 5 || hash == "" {
		t.Fatalf("card %d: %s", code, card)
	}
	if out, code := run(bin, "intent", "approve", "fixture", hash); code != 0 {
		t.Fatalf("approve %d: %s", code, out)
	}
	stopped, code := run(bin, "intent", "build", "fixture")
	if code == 0 || !strings.Contains(stopped, "executor/usage_limit") {
		t.Fatalf("build %d: %s", code, stopped)
	}
	runs := filepath.Join(project, ".kogen/local/runs")
	dirs, err := os.ReadDir(runs)
	if err != nil || len(dirs) != 1 {
		t.Fatalf("runs %v %v", dirs, err)
	}
	id := dirs[0].Name()
	read := func(p string) []byte {
		t.Helper()
		d, e := os.ReadFile(p)
		if e != nil {
			t.Fatal(e)
		}
		return d
	}
	oldLog := string(read(filepath.Join(runs, id, "log.jsonl")))
	checkpoint := read(filepath.Join(runs, id, "checkpoint.json"))
	result := read(filepath.Join(runs, id, "result.json"))
	var doc struct {
		State struct {
			Round        int `json:"round"`
			Pass         int `json:"pass"`
			Continuation struct {
				Stage string `json:"stage"`
			} `json:"continuation"`
		} `json:"state"`
	}
	if err := json.Unmarshal(checkpoint, &doc); err != nil || doc.State.Round != limit || doc.State.Pass != limit-1 || doc.State.Continuation.Stage != "builder_usage_limit" {
		t.Fatalf("checkpoint %s %v", checkpoint, err)
	}
	for i := 1; i < limit; i++ {
		if !strings.Contains(oldLog, fmt.Sprintf(`"event":"executor_round","executor":"claude-code"`)) || !strings.Contains(oldLog, fmt.Sprintf(`"green":false`)) {
			t.Fatalf("missing previous rounds/passes: %s", oldLog)
		}
	}
	if h, _ := run("git", "rev-parse", "HEAD"); strings.TrimSpace(h) != start {
		t.Fatal("stop committed")
	}
	for i := 1; i < limit; i++ {
		read(filepath.Join(project, fmt.Sprintf("marker%d.txt", i)))
	}
	read(filepath.Join(project, "partial.txt"))
	resumed, code := run(bin, "intent", "resume", id)
	if code != 0 || !strings.Contains(resumed, "fresh conversation") {
		t.Fatalf("resume %d: %s", code, resumed)
	}
	prompt := string(read(filepath.Join(state, fmt.Sprintf("prompt-build-%d.txt", limit+1))))
	for _, text := range []string{"fresh executor conversation", fmt.Sprintf("logical round %d", limit), "Previous verification feedback", "Verification pass"} {
		if !strings.Contains(prompt, text) {
			t.Fatalf("prompt missing %q: %s", text, prompt)
		}
	}
	sessions := strings.Split(strings.TrimSpace(string(read(filepath.Join(state, "sessions.jsonl")))), "\n")
	var buildSessions []map[string]any
	for _, line := range sessions {
		var v map[string]any
		if json.Unmarshal([]byte(line), &v) != nil {
			t.Fatal(line)
		}
		if v["role"] == "build" {
			buildSessions = append(buildSessions, v)
		}
	}
	if len(buildSessions) != limit+1 || buildSessions[limit]["start"] == nil || buildSessions[limit]["resume"] != nil {
		t.Fatalf("sessions %v", buildSessions)
	}
	// The first session continues through the limited invocation; only the explicit
	// resume starts a different provider session at the same logical round.
	first := buildSessions[0]["start"]
	if first == nil {
		t.Fatal("missing initial session")
	}
	for i := 1; i < limit; i++ {
		if buildSessions[i]["resume"] != first {
			t.Fatalf("round %d did not continue first session: %v", i+1, buildSessions)
		}
	}
	if buildSessions[limit]["start"] == first {
		t.Fatalf("resume reused provider session: %v", buildSessions)
	}
	for i := 1; i < limit; i++ {
		if string(read(filepath.Join(project, fmt.Sprintf("marker%d.txt", i)))) != "complete\n" {
			t.Fatal("completed marker changed")
		}
	}
	if string(read(filepath.Join(project, "partial.txt"))) != "partial\n" {
		t.Fatal("partial marker changed")
	}
	if string(read(filepath.Join(runs, id, "checkpoint.json"))) != string(checkpoint) || string(read(filepath.Join(runs, id, "result.json"))) != string(result) {
		t.Fatal("prior run changed")
	}
	if count, _ := run("git", "rev-list", "--count", start+"..HEAD"); strings.TrimSpace(count) != "1" {
		t.Fatalf("commit count %s", count)
	}
	dirs, _ = os.ReadDir(runs)
	if len(dirs) != 2 {
		t.Fatalf("runs %v", dirs)
	}
	for _, d := range dirs {
		if d.Name() != id {
			res := string(read(filepath.Join(runs, d.Name(), "result.json")))
			log := string(read(filepath.Join(runs, d.Name(), "log.jsonl")))
			if !strings.Contains(log, fmt.Sprintf(`"pass":%d`, limit)) || !strings.Contains(log, `"green":true`) || !strings.Contains(log, `"verdict":"approve"`) || !strings.Contains(log, `"role":"review"`) || !strings.Contains(log, fmt.Sprintf(`"round":%d`, limit)) {
				t.Fatalf("missing fresh verification or independent review: %s", log)
			}
			for i := 1; i < limit; i++ {
				if !strings.Contains(oldLog, fmt.Sprintf(`"round":%d`, i)) || !strings.Contains(oldLog, fmt.Sprintf(`"pass":%d`, i)) {
					t.Fatalf("missing historical round %d: %s", i, oldLog)
				}
			}
			if !strings.Contains(oldLog, fmt.Sprintf(`"round":%d`, limit)) {
				t.Fatalf("missing interrupted round: %s", oldLog)
			}
			if !strings.Contains(res, `"resumed_from":"`+id+`"`) || !strings.Contains(res, `"outcome":"landed"`) {
				t.Fatalf("lineage: %s", res)
			}
		}
	}
}

func TestUsageLimitPackagingIsolationRound2(t *testing.T) { usageIsolation(t, 2) }
func TestUsageLimitPackagingIsolationRound3(t *testing.T) { usageIsolation(t, 3) }
func usageIsolation(t *testing.T, round int) {
	root, check := testrelease.Fixture(t, repoRoot(t))
	defer check()
	usageLimitInstalledFrom(t, round, root)
}

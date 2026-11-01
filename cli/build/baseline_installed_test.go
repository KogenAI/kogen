package build

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"testing"

	"kogen/internal/testrelease"
	"kogen/project"
)

func TestBaselinePerBaseInstalled(t *testing.T) {
	t.Parallel()
	source, err := filepath.Abs("../..")
	if err != nil {
		t.Fatal(err)
	}
	baselineInstalledFrom(t, source)
}
func baselineInstalledFrom(t *testing.T, source string) {
	archive := testrelease.Package(t, source)
	unpack := t.TempDir()
	cmd := exec.Command("tar", "-xzf", archive, "-C", unpack)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("unpack: %v %s", err, out)
	}
	entries, err := os.ReadDir(unpack)
	if err != nil || len(entries) != 1 {
		t.Fatalf("archive contents: %v %v", entries, err)
	}
	prefix := filepath.Join(t.TempDir(), "install")
	cmd = exec.Command("sh", filepath.Join(unpack, entries[0].Name(), "install.sh"), "--prefix", prefix)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("install: %v %s", err, out)
	}
	bin := filepath.Join(prefix, "bin", "kogen")
	e := newEnv(t, func(c *project.Config) { c.Checks = []project.Check{{Name: "closed", Run: ":"}} })
	e.credentials()
	e.run("git", "add", project.IntentMDPath(testSlug), project.FeaturePath(testSlug), stepsFile)
	e.run("git", "commit", "-qm", "approved fixture")
	base := e.head()
	main := e.root
	var logs [][]map[string]any
	var firstLog string
	for i := 0; i < 3; i++ {
		root := filepath.Join(t.TempDir(), "tree")
		revision := base
		if i == 2 {
			e.root = main
			e.write("app.txt", "baseline!\n")
			e.run("git", "add", "app.txt")
			e.run("git", "commit", "-qm", "one byte")
			revision = e.head()
		}
		e.root = main
		e.run("git", "worktree", "add", "-q", "-b", fmtBranch(i), root, revision)
		e.root = root
		code, card := e.cli(bin, "intent", "approve", testSlug)
		hash := regexp.MustCompile(`\b[0-9a-f]{64}\b`).FindString(card)
		if code != 5 || hash == "" {
			t.Fatalf("card %d: %s", code, card)
		}
		code, approval := e.cli(bin, "intent", "approve", testSlug, hash)
		if code != 0 {
			t.Fatalf("approval %d: %s", code, approval)
		}
		e.prov.then(landScript(e.prov)...)
		e.prov.then(submit(e.prov, "approve"))
		code, buildOut := e.cli(bin, "intent", "build", testSlug)
		if code != 0 {
			t.Fatalf("build %d: %s", code, buildOut)
		}
		id := e.onlyRun()
		if i == 0 {
			firstLog = filepath.Join(root, ".kogen/local/runs", id, "log.jsonl")
		}
		logs = append(logs, e.events(id))
	}
	first, second, third := logs[0], logs[1], logs[2]
	baselineCommands := func(events []map[string]any) int {
		n := 0
		for _, event := range events {
			if event["event"] == "command" && event["name"] == "closed" && event["before_change"] == true {
				n++
			}
		}
		return n
	}
	if baselineCommands(first) != 1 || len(eventsNamed(first, "baseline_reuse")) != 0 {
		t.Fatalf("first events: %v", first)
	}
	hits := eventsNamed(second, "baseline_reuse")
	if baselineCommands(second) != 0 || len(hits) != 1 || hits[0]["name"] != "closed" || hits[0]["evidence"] != firstLog || hits[0]["identity"] == "" {
		t.Fatalf("second events: %v", second)
	}
	if baselineCommands(third) != 1 || len(eventsNamed(third, "baseline_reuse")) != 0 {
		t.Fatalf("third events: %v", third)
	}
}

func fmtBranch(i int) string { return []string{"trial-one", "trial-two", "trial-three"}[i] }

func TestBaselinePackagingIsolation(t *testing.T) {
	source, err := filepath.Abs("../..")
	if err != nil {
		t.Fatal(err)
	}
	root, check := testrelease.Fixture(t, source)
	defer check()
	baselineInstalledFrom(t, root)
}

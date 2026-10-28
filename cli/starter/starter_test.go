package starter

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"testing"

	"kogen/project"
)

func TestEmbeddedConfig(t *testing.T) {
	data, err := files.ReadFile("files/.kogen/project.yaml")
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := project.ParseConfig(string(data), ".kogen/project.yaml")
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(cfg.Models, project.DefaultModels()) {
		t.Fatalf("models %+v", cfg.Models)
	}
	if string(data) != project.RenderConfig(cfg) {
		t.Fatal("project.yaml is not RenderConfig output")
	}
}

func TestLibExportsOnlyTitleCase(t *testing.T) {
	data, _ := files.ReadFile("files/lib/text.js")
	if !strings.Contains(string(data), "module.exports = { titleCase };") || strings.Contains(string(data), "slugify") {
		t.Fatal("lib/text.js exports")
	}
}

func setupHome(t *testing.T, identity bool) {
	home := t.TempDir()
	cfg := filepath.Join(home, ".gitconfig")
	body := ""
	if identity {
		body = "[user]\n\tname = T\n\temail = t@example.invalid\n"
	}
	os.WriteFile(cfg, []byte(body), 0o644)
	t.Setenv("HOME", home)
	t.Setenv("GIT_CONFIG_GLOBAL", cfg)
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	t.Chdir(t.TempDir())
}

func TestCreateAndRefusals(t *testing.T) {
	setupHome(t, true)
	os.Mkdir("busy", 0o755)
	os.WriteFile("busy/x", nil, 0o644)
	os.WriteFile("file", nil, 0o644)
	for _, d := range []string{"busy", "file"} {
		if err := Create(d); err == nil || !strings.Contains(err.Error(), "starter_target_not_empty") {
			t.Fatalf("%s: %v", d, err)
		}
	}
	os.Mkdir("empty", 0o755)
	if err := Create("empty"); err != nil {
		t.Fatal(err)
	}
	out, _ := exec.Command("git", "-C", "empty", "log", "--format=%s").Output()
	if strings.TrimSpace(string(out)) != commitSubject {
		t.Fatalf("log %q", out)
	}
	st, _ := exec.Command("git", "-C", "empty", "status", "--porcelain").Output()
	if len(st) != 0 {
		t.Fatalf("dirty %q", st)
	}
}

func TestNoIdentityWritesNothing(t *testing.T) {
	setupHome(t, false)
	err := Create("a/b")
	if err == nil || !strings.Contains(err.Error(), "git_identity_missing") {
		t.Fatal(err)
	}
	if _, err := os.Stat("a"); err == nil {
		t.Fatal("created")
	}
}

func TestRequestExamplesMatchReference(t *testing.T) {
	data, err := files.ReadFile("files/request.md")
	if err != nil {
		t.Fatal(err)
	}
	re := regexp.MustCompile(`(?m)^- ("(?:[^"\\]|\\.)*") → ("(?:[^"\\]|\\.)*")$`)
	nonAlnum := regexp.MustCompile(`[^a-z0-9]+`)
	matches := re.FindAllStringSubmatch(string(data), -1)
	if len(matches) != 3 {
		t.Fatalf("examples %q", matches)
	}
	for _, m := range matches {
		var in, want string
		if json.Unmarshal([]byte(m[1]), &in) != nil || json.Unmarshal([]byte(m[2]), &want) != nil {
			t.Fatalf("not JSON strings: %q", m[0])
		}
		if got := strings.Trim(nonAlnum.ReplaceAllString(strings.ToLower(in), "-"), "-"); got != want {
			t.Fatalf("slugify(%q) = %q, request says %q", in, got, want)
		}
	}
}

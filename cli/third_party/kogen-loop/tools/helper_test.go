package tools

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"kogen-loop/sys"
)

// hermeticEnv is the process environment without the user's or the system's Git
// configuration, so Git's output is the same on every machine.
func hermeticEnv() []string {
	var env []string
	for _, kv := range os.Environ() {
		if !strings.HasPrefix(kv, "GIT_") {
			env = append(env, kv)
		}
	}
	return append(env, "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1")
}

// gitIn runs git in dir and fails the test when it fails.
func gitIn(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"}, args...)...)
	cmd.Dir = dir
	cmd.Env = hermeticEnv()
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return string(out)
}

// newRepo is an empty repository in a fresh temporary folder (its real path).
func newRepo(t *testing.T) (base, root string) {
	t.Helper()
	base, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	root = filepath.Join(base, "repo")
	if err := os.Mkdir(root, 0o755); err != nil {
		t.Fatal(err)
	}
	gitIn(t, root, "init", "-q")
	return base, root
}

// write creates a file with its folders.
func write(t *testing.T, root, path, content string) {
	t.Helper()
	full := filepath.Join(root, path)
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// commitAll commits every file, so HEAD exists.
func commitAll(t *testing.T, root string) {
	t.Helper()
	gitIn(t, root, "add", "-A")
	gitIn(t, root, "commit", "-q", "-m", "init")
}

// newTools is Tools for root with the hermetic Git environment and these tools enabled.
func newTools(root string, enabled ...string) *Tools {
	return &Tools{Root: root, Session: sys.NewWith(hermeticEnv(), root), Enabled: enabled}
}

// ---- the Elixir-generated golden file ----

type goldenFile struct {
	Path    string `json:"path"`
	Content string `json:"content"`
	B64     string `json:"b64"`
	Link    string `json:"link"`
}

type goldenCall struct {
	Name      string          `json:"name"`
	Arguments string          `json:"arguments"`
	Result    json.RawMessage `json:"result"`
}

type golden struct {
	Files     []goldenFile `json:"files"`
	Tracked   []string     `json:"tracked"`
	Tools     []string     `json:"tools"`
	Protected []string     `json:"protected"`
	Calls     []goldenCall `json:"calls"`
}

func loadGolden(t *testing.T) golden {
	t.Helper()
	data, err := os.ReadFile("testdata/tools_golden.json")
	if err != nil {
		t.Fatal(err)
	}
	var g golden
	if err := json.Unmarshal(data, &g); err != nil {
		t.Fatal(err)
	}
	return g
}

// build creates the golden repository: the files, the tracked ones committed.
func (g golden) build(t *testing.T) (base, root string) {
	t.Helper()
	base, root = newRepo(t)
	for _, f := range g.Files {
		full := filepath.Join(root, f.Path)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		switch {
		case f.Link != "":
			if err := os.Symlink(f.Link, full); err != nil {
				t.Fatal(err)
			}
		case f.B64 != "":
			b, err := base64.StdEncoding.DecodeString(f.B64)
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(full, b, 0o644); err != nil {
				t.Fatal(err)
			}
		default:
			if err := os.WriteFile(full, []byte(f.Content), 0o644); err != nil {
				t.Fatal(err)
			}
		}
	}
	gitIn(t, root, append([]string{"add", "--"}, g.Tracked...)...)
	gitIn(t, root, "commit", "-q", "-m", "init")
	return base, root
}

func (g golden) file(t *testing.T, path string) []byte {
	t.Helper()
	for _, f := range g.Files {
		if f.Path == path {
			if f.B64 != "" {
				b, _ := base64.StdEncoding.DecodeString(f.B64)
				return b
			}
			return []byte(f.Content)
		}
	}
	t.Fatalf("no golden file %s", path)
	return nil
}

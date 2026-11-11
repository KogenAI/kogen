package main

import (
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"kogen/internal/testrelease"
)

// The installed-release tests share one release per test process; remove it once they are done.
func TestMain(m *testing.M) {
	code := m.Run()
	testrelease.Cleanup()
	if buildDir != "" {
		os.RemoveAll(buildDir)
	}
	os.Exit(code)
}

// approveShortBound is the step bound of the binary the deadline tests drive: the product's 120
// seconds shortened to a fixed test constant so those tests finish in seconds.
const approveShortBound = 10 * time.Second

var (
	cliOnce, shortOnce sync.Once
	cliBin, shortBin   string
	cliErr, shortErr   error
	buildDir           string
	buildDirOnce       sync.Once
	buildDirErr        error
)

func testBuildDir() (string, error) {
	buildDirOnce.Do(func() { buildDir, buildDirErr = os.MkdirTemp("", "kogen-cli-test-") })
	return buildDir, buildDirErr
}

// sharedCLI is the kogen binary built once for every test that drives the CLI.
func sharedCLI(t *testing.T) string {
	t.Helper()
	cliOnce.Do(func() { cliBin, cliErr = buildCLI("kogen", nil) })
	if cliErr != nil {
		t.Fatal(cliErr)
	}
	return cliBin
}

// shortBoundCLI is a kogen binary built once whose verification step bound is approveShortBound.
func shortBoundCLI(t *testing.T) string {
	t.Helper()
	shortOnce.Do(func() {
		out, err := exec.Command("go", "list", "-m", "-f", "{{.Dir}}", "github.com/KogenAI/kogen-verification").Output()
		if err != nil {
			shortErr = fmt.Errorf("go list: %v", err)
			return
		}
		modDir := strings.TrimSpace(string(out))
		dir, err := testBuildDir()
		if err != nil {
			shortErr = err
			return
		}
		// Go refuses overlays inside the module cache, so build against a patched copy of the
		// module named by a temporary go.mod.
		patched := filepath.Join(dir, "kogen-verification")
		if shortErr = copyTree(modDir, patched); shortErr != nil {
			return
		}
		attempt := filepath.Join(patched, "verify", "attempt.go")
		src, err := os.ReadFile(attempt)
		if err != nil {
			shortErr = err
			return
		}
		const from = "const StepTimeout = 120 * time.Second"
		if !strings.Contains(string(src), from) {
			shortErr = fmt.Errorf("%s no longer declares %q", attempt, from)
			return
		}
		to := fmt.Sprintf("const StepTimeout = %d * time.Second", int(approveShortBound/time.Second))
		if shortErr = os.WriteFile(attempt, []byte(strings.Replace(string(src), from, to, 1)), 0o644); shortErr != nil {
			return
		}
		mod, err := os.ReadFile("go.mod")
		if err != nil {
			shortErr = err
			return
		}
		sum, err := os.ReadFile("go.sum")
		if err != nil {
			shortErr = err
			return
		}
		modfile := filepath.Join(dir, "short.mod")
		mod = append(mod, fmt.Sprintf("\nreplace github.com/KogenAI/kogen-verification => %s\n", patched)...)
		if shortErr = os.WriteFile(modfile, mod, 0o644); shortErr != nil {
			return
		}
		if shortErr = os.WriteFile(filepath.Join(dir, "short.sum"), sum, 0o644); shortErr != nil {
			return
		}
		shortBin, shortErr = buildCLI("kogen-short", []string{"-modfile=" + modfile})
	})
	if shortErr != nil {
		t.Fatal(shortErr)
	}
	return shortBin
}

func buildCLI(name string, flags []string) (string, error) {
	dir, err := testBuildDir()
	if err != nil {
		return "", err
	}
	bin := filepath.Join(dir, name)
	args := append(append([]string{"build"}, flags...), "-o", bin, ".")
	if out, err := exec.Command("go", args...).CombinedOutput(); err != nil {
		return "", fmt.Errorf("go build: %v\n%s", err, out)
	}
	return bin, nil
}

func copyExecutable(from, to string) error {
	in, err := os.Open(from)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(to, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o755)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

// copyTree copies a directory of regular files, making every copy writable.
func copyTree(from, to string) error {
	return filepath.WalkDir(from, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(from, path)
		dest := filepath.Join(to, rel)
		if d.IsDir() {
			return os.MkdirAll(dest, 0o755)
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		return os.WriteFile(dest, b, 0o644)
	})
}

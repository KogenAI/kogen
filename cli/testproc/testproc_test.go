package testproc

import (
	"os"
	"os/exec"
	"strings"
	"testing"
)

func TestIsolation(t *testing.T) {
	if !Isolate(t, "TESTPROC_VALUE=outer") {
		return
	}
	if os.Getenv("TESTPROC_VALUE") != "outer" {
		t.Fatal("outer environment")
	}
	t.Run("nested", func(t *testing.T) {
		if !Isolate(t, "TESTPROC_VALUE=inner") {
			t.Fatal("forked nested test")
		}
		if os.Getenv("TESTPROC_VALUE") != "inner" {
			t.Fatal("inner environment")
		}
	})
	if os.Getenv("TESTPROC_VALUE") != "outer" {
		t.Fatal("nested environment leaked")
	}
}

func TestNames(t *testing.T) {
	for _, name := range []string{"a+b", "axb", "a+b_more"} {
		t.Run(name, func(t *testing.T) {
			if !Isolate(t) {
				return
			}
			if os.Getenv("TESTPROC_SELECTED") != "" && !strings.HasSuffix(t.Name(), "/a+b") {
				t.Fatal("wrong selection")
			}
		})
	}
}

func TestSelection(t *testing.T) {
	cmd := exec.Command(os.Args[0], "-test.run=^TestNames$/^a\\+b$", "-test.v")
	cmd.Env = append(os.Environ(), "TESTPROC_SELECTED=1")
	output, err := cmd.CombinedOutput()
	if err != nil || strings.Contains(string(output), "TestNames/axb") || strings.Contains(string(output), "TestNames/a+b_more") {
		t.Fatalf("selection: %v\n%s", err, output)
	}
}

func TestOutcomeFixture(t *testing.T) {
	switch os.Getenv("TESTPROC_OUTCOME") {
	case "fail", "skip":
	default:
		t.Skip("fixture")
	}
	if !Isolate(t) {
		return
	}
	if os.Getenv("TESTPROC_OUTCOME") == "fail" {
		t.Fatal("isolated failure 1414")
	}
	t.Skip("isolated skip 3141")
}
func TestOutcomes(t *testing.T) {
	for _, mode := range []string{"fail", "skip"} {
		cmd := exec.Command(os.Args[0], "-test.run=^TestOutcomeFixture$", "-test.v")
		cmd.Env = append(os.Environ(), "TESTPROC_OUTCOME="+mode)
		out, err := cmd.CombinedOutput()
		if (err != nil) != (mode == "fail") || !strings.Contains(string(out), "isolated "+mode) || !strings.Contains(string(out), "--- "+strings.ToUpper(mode)+": TestOutcomeFixture") {
			t.Errorf("%s: %v\n%s", mode, err, out)
		}
	}
}

func TestMissingResultFixture(t *testing.T) {
	if os.Getenv("TESTPROC_MISSING") != "1" {
		t.Skip("fixture")
	}
	if !Isolate(t) {
		return
	}
	os.Exit(0)
}

func TestMissingResultFails(t *testing.T) {
	cmd := exec.Command(os.Args[0], "-test.run=^TestMissingResultFixture$", "-test.v")
	cmd.Env = append(os.Environ(), "TESTPROC_MISSING=1")
	out, err := cmd.CombinedOutput()
	if err == nil || !strings.Contains(string(out), "child missing result") {
		t.Fatalf("missing result: %v\n%s", err, out)
	}
}

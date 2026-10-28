// Package starter creates the embedded starter project (kogen starter).
package starter

import (
	"embed"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"

	"kogen-loop/sys"
	"kogen/git"
)

//go:embed all:files
var files embed.FS

const commitSubject = "Add Kogen starter project"

// Create writes the starter project into dir and commits it. Both preconditions are
// checked before anything is written: the target first, then the Git identity.
func Create(dir string) error {
	if err := checkTarget(dir); err != nil {
		return err
	}
	cwd, _ := os.Getwd()
	if git.New(cwd, nil).Identity() == "" {
		return sys.Fail("environment", "git_identity_missing", `no Git identity for the commit; run git config user.name "<name>" and git config user.email "<email>" (global or repository)`, 3)
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return failWrite(err)
	}
	err := fs.WalkDir(files, "files", func(p string, d fs.DirEntry, err error) error {
		if err != nil || p == "files" {
			return err
		}
		dest := filepath.Join(dir, p[len("files/"):])
		if d.IsDir() {
			return os.MkdirAll(dest, 0o755)
		}
		data, err := files.ReadFile(p)
		if err != nil {
			return err
		}
		return os.WriteFile(dest, data, 0o644)
	})
	if err != nil {
		return failWrite(err)
	}
	for _, args := range [][]string{{"init", "-q"}, {"add", "-A"}, {"commit", "-q", "-m", commitSubject}} {
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		cmd.Env = git.CleanEnv(os.Environ())
		if out, err := cmd.CombinedOutput(); err != nil {
			return sys.Fail("environment", "starter_git_failed", "git "+args[0]+": "+string(out), 3)
		}
	}
	return nil
}

func failWrite(err error) error {
	return sys.Fail("environment", "starter_write_failed", err.Error(), 3)
}

func checkTarget(dir string) error {
	st, err := os.Stat(dir)
	if os.IsNotExist(err) {
		return nil
	}
	empty := false
	if err == nil && st.IsDir() {
		entries, rerr := os.ReadDir(dir)
		empty = rerr == nil && len(entries) == 0
	}
	if empty {
		return nil
	}
	return sys.Fail("environment", "starter_target_not_empty", dir+" already exists and is not empty; choose a new or empty directory (nothing was changed)", 3)
}

// NextCommands is the text printed after a successful Create.
func NextCommands(dir string) string {
	return "cd " + dir + "\nkogen doctor\nkogen intent shape slugify request.md\n" +
		"kogen intent approve slugify   # shows the card; run the approve command it prints\n" +
		"kogen intent build slugify\n"
}

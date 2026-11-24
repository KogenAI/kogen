package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"

	"github.com/KogenAI/kogen-executor/executor/claudecode"
	"github.com/KogenAI/kogen-loop/sys"
	"github.com/KogenAI/kogen-verification/verify"
	"kogen/readiness"
)

func must(err error) {
	if err != nil {
		panic(err)
	}
}

func write(path, text string, mode os.FileMode) {
	must(os.MkdirAll(filepath.Dir(path), 0o700))
	must(os.WriteFile(path, []byte(text), mode))
}

func main() {
	if _, supported := claudecode.Supported(); !supported {
		panic("fixture requires a supported Claude Code platform")
	}
	code, err := strconv.Atoi(os.Args[1])
	must(err)
	payload, err := io.ReadAll(os.Stdin)
	must(err)
	base, err := os.MkdirTemp("", "readiness-auth-")
	must(err)
	defer os.RemoveAll(base)
	root, home := filepath.Join(base, "project"), filepath.Join(base, "home")
	write(filepath.Join(root, ".kogen/project.yaml"), "version: 1\n", 0o600)
	write(filepath.Join(root, ".kogen/models.yaml"), "models:\n  shape: {executor: claude-code, model: claude-sonnet-5-5, effort: medium}\n  build: {executor: claude-code, model: claude-sonnet-5-5, effort: medium}\n  review: {executor: claude-code, model: claude-sonnet-5-5, effort: medium}\n", 0o600)
	body, marker := filepath.Join(base, "auth.json"), filepath.Join(base, "auth-probed")
	write(body, string(payload), 0o600)
	script := fmt.Sprintf("#!/bin/sh\ncase \"$*\" in\n  --version) echo '%s (Claude Code)'; exit 0 ;;\n  'auth status --json') touch %q; cat %q; exit %d ;;\n  *) exit 99 ;;\nesac\n", claudecode.Version, marker, body, code)
	write(claudecode.RuntimePath(home), script, 0o700)
	must(os.Setenv(claudecode.SeamEnv, "http://127.0.0.1:1"))
	env := append(os.Environ(), "GIT_CEILING_DIRECTORIES="+base, "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1")
	checks := readiness.Run(sys.NewWith(env, root), readiness.Input{Project: root, Home: home, Version: "fixture", Tools: verify.Tools{Node: "/bin/true"}})
	for _, check := range checks {
		if check.Check == "models" {
			_, probeErr := os.Stat(marker)
			must(json.NewEncoder(os.Stdout).Encode(struct {
				Check      readiness.Check
				Text       string
				AuthProbed bool
			}{check, readiness.Text([]readiness.Check{check}), probeErr == nil}))
			return
		}
	}
	panic("readiness.Run returned no models check")
}

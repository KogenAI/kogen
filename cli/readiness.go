package main

import (
	"os"

	"github.com/KogenAI/kogen-verification/verify"
	"kogen-loop/sys"
	"kogen/readiness"
)

// printReadiness ends a successful `kogen init` with the readiness lines. A failing line never
// changes the exit code.
func printReadiness(s *sys.Session, root, project string) {
	home, _ := os.UserHomeDir()
	s.Out(readiness.Text(readiness.Run(s, readiness.Input{Project: project, Tools: verify.ToolsFromInstall(root),
		Version: versionLine(root), Home: home})))
}

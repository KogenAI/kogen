package main

import (
	"os"

	"github.com/KogenAI/kogen-coordinator/git"
	projectpkg "github.com/KogenAI/kogen-coordinator/project"

	"github.com/KogenAI/kogen-loop/sys"
	"github.com/KogenAI/kogen-verification/verify"
	"kogen/readiness"
)

// printReadiness ends a successful `kogen init` with the readiness lines. A failing line never
// changes the exit code.
func printReadiness(s *sys.Session, root, project string) {
	home, _ := os.UserHomeDir()
	checks := readiness.Run(s, readiness.Input{Project: project, Tools: verify.ToolsFromInstall(root),
		Version: versionLine(root), Home: home})
	s.Out(readiness.Text(checks))
	for _, check := range checks {
		if check.Status != "ok" {
			return
		}
	}
	repo, err := git.OpenReadOnly(project, s.Env)
	if err != nil {
		return
	}
	cfg, err := projectpkg.LoadConfig(repo.Dir)
	if err == nil && cfg.Acceptance != nil && cfg.Acceptance.Run != "" && cfg.Acceptance.StepsDir != "" && len(cfg.Checks) > 0 {
		s.Puts("Next: kogen intent shape <slug> <request-file>")
	}
}

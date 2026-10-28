package main

import (
	"os"

	"kogen-loop/sys"
	"kogen/doctor"
	"kogen/verify"
)

// runDoctor is `kogen doctor`: exit 0 when no check failed, 1 otherwise.
func runDoctor(inv *invocation, root string) int {
	s := sys.New()
	stop := s.WatchSignals()
	defer stop()
	defer func() { sys.Terminate(s.Groups()) }()
	project := s.Cwd
	if inv.project != "" {
		project = absFrom(s.Cwd, inv.project)
	}
	checks, err := runChecks(s, root, project, inv.quick)
	if err != nil {
		return exitFor(err)
	}
	if inv.json {
		s.Out(doctor.JSON(checks))
	} else {
		s.Out(doctor.Text(checks))
	}
	if doctor.Failed(checks) {
		return 1
	}
	return 0
}

// printDoctor prints the text report, as the end of `kogen init` does.
func printDoctor(s *sys.Session, root, project string, quick bool) error {
	checks, err := runChecks(s, root, project, quick)
	if err != nil {
		return err
	}
	s.Out(doctor.Text(checks))
	return nil
}

func runChecks(s *sys.Session, root, project string, quick bool) ([]doctor.Check, error) {
	home, _ := os.UserHomeDir()
	return doctor.Run(s.Context(), s, doctor.Input{Project: project, Quick: quick, Tools: verify.ToolsFromInstall(root),
		Version: versionLine(root), Home: home})
}

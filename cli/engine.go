package main

import (
	"context"
	"errors"
	"os"

	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen/build"
	"kogen/executor"
	"kogen/executor/claudecode"
	"kogen/project"
	"kogen/shape"
	"kogen/verify"
)

// engineJob is an Intent command or init after the command line and the caller's files were
// checked: the project, the request text and where it came from, the Build's diagnostic data.
type engineJob struct {
	output      string // intent recover --output
	inv         *invocation
	root        string // the installation root
	project     string
	request     string
	requestPath string // empty when the request came from stdin
	diagnostic  *build.Diagnostic
}

// externalExecutor is the program's external build executors (docs/executor-contract.md):
// Claude Code, run on the user's own sign-in, with this binary's hidden hook subcommand as its
// write-prevention hook. Any other executor name is refused when the configuration is read.
func externalExecutor(role project.Role) (executor.Executor, error) {
	if role.Executor != project.ExecutorClaudeCode {
		return nil, executor.Fail(executor.ReasonUnavailable, "executor "+role.Executor+" is not available in this program")
	}
	exe, err := os.Executable()
	if err != nil {
		return nil, executor.Fail(executor.ReasonUnavailable, "cannot locate this program for the executor hooks: "+err.Error())
	}
	home, _ := os.UserHomeDir()
	token, _ := provider.ClaudeCodeToken(home)
	return claudecode.New(claudecode.Options{HookCommand: []string{exe, claudecode.HookSubcommand}, Token: token}), nil
}

// runEngine runs the Intent commands and init and returns the exit code.
func runEngine(job engineJob) int {
	inv := job.inv
	s := sys.New()
	s.Debug("kogen " + inv.command + " in " + s.Cwd)
	stop := s.WatchSignals()
	defer stop()
	// Nothing a command started outlives the invocation: stop every command group (LOOP-5).
	defer func() { sys.Terminate(s.Groups()) }()
	tools := verify.ToolsFromInstall(job.root)
	client := provider.NewClient(versionLine(job.root))
	var code int
	var err error
	switch inv.command {
	case "init":
		code, err = shape.Init(s.Context(), s, shape.InitInput{Client: client, Tools: tools})
	case "shape":
		code, err = shape.Shape(s.Context(), s, shape.ShapeInput{Project: job.project, Slug: inv.slug,
			Request: job.request, RequestPath: job.requestPath, Tools: tools, InstallRoot: job.root, Client: client, External: externalExecutor})
	case "refine":
		code, err = shape.Refine(s.Context(), s, shape.RefineInput{Project: job.project, Slug: inv.slug, Hash: inv.hash,
			Request: job.request, RequestPath: job.requestPath, Tools: tools, InstallRoot: job.root, Client: client, External: externalExecutor})
	case "approve":
		code, err = shape.Approve(s.Context(), s, shape.ApproveInput{Project: job.project, Slug: inv.slug,
			Hash: inv.hash, By: inv.by, Tools: tools})
	case "build":
		code, err = build.Build(s.Context(), s, build.Input{Deps: build.Deps{Client: client, Tools: tools, External: externalExecutor},
			Project: job.project, Slug: inv.slug, Context: job.diagnostic})
	case "resume":
		code, err = build.Resume(s.Context(), s, build.ResumeInput{Deps: build.Deps{Client: client, Tools: tools, External: externalExecutor},
			Project: job.project, ID: inv.slug})
	case "recover":
		code, err = build.Recover(s.Context(), s, build.RecoverInput{Project: job.project, ID: inv.slug, Output: job.output})
	}
	if err != nil {
		// A cancellation that surfaces after the caller interrupted is that interrupt: exit
		// 130/143/129, never an internal error (CLI-5).
		if ie := s.Err(); ie != nil && errors.Is(err, context.Canceled) {
			err = ie
		}
		return exitFor(err)
	}
	return code
}

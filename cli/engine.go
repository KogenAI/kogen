package main

import (
	"context"
	"errors"

	"kogen/build"
	"kogen/provider"
	"kogen/shape"
	"kogen/sys"
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
			Request: job.request, RequestPath: job.requestPath, Tools: tools, InstallRoot: job.root, Client: client})
	case "refine":
		code, err = shape.Refine(s.Context(), s, shape.RefineInput{Project: job.project, Slug: inv.slug, Hash: inv.hash,
			Request: job.request, RequestPath: job.requestPath, Tools: tools, InstallRoot: job.root, Client: client})
	case "approve":
		code, err = shape.Approve(s.Context(), s, shape.ApproveInput{Project: job.project, Slug: inv.slug,
			Hash: inv.hash, By: inv.by, Tools: tools})
	case "build":
		code, err = build.Build(s.Context(), s, build.Input{Deps: build.Deps{Client: client, Tools: tools},
			Project: job.project, Slug: inv.slug, Context: job.diagnostic})
	case "resume":
		code, err = build.Resume(s.Context(), s, build.ResumeInput{Deps: build.Deps{Client: client, Tools: tools},
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

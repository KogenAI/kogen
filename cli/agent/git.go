package agent

import (
	"kogen/git"

	"kogen-loop/tools"
)

// Git adapts a Kogen repository to the Git of kogen-loop's tools, so list_files, search_text
// and the view_image candidate run through the same environment scrubbing, exit mapping and
// error text as every other Kogen Git command. Run converts the result; Head and Tree are
// the repository's own. A nil repository is a nil Git, which tools replaces by its own runner
// in the tools root, as a nil Tools.Repo always did.
func Git(r *git.Repo) tools.Git {
	if r == nil {
		return nil
	}
	return gitRepo{r}
}

type gitRepo struct{ r *git.Repo }

func (g gitRepo) Run(args ...string) (tools.GitResult, error) {
	res, err := g.r.Run(args...)
	return tools.GitResult{Stdout: res.Stdout, Stderr: res.Stderr, Status: res.Status}, err
}

func (g gitRepo) Head() string { return g.r.Head() }

func (g gitRepo) Tree(start string, excluded []string) (string, error) {
	return g.r.Tree(start, excluded)
}

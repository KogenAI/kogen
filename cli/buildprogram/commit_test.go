package buildprogram

import ()

// stageOtherIntent stages an Intent of another Build, which must stay out of the candidate.
func (e *env) stageOtherIntent() {
	e.write(".kogen/intents/staged/draft.md", "caller staged this Intent\n")
	e.run("git", "add", ".kogen/intents/staged/draft.md")
}

func (e *env) staged() string { return e.gitOut("diff", "--cached", "--name-only") }

package buildprogram

import (
	"strings"
)

func (e *env) gitOutSafe(args ...string) string {
	out, _ := execGit(e, args...)
	return strings.TrimSpace(out)
}

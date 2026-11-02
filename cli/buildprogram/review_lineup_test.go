package buildprogram

import ()

func (e *env) commitsSince(start string) string {
	return e.gitOut("rev-list", "--count", start+"..HEAD")
}

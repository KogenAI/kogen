package verify

import "strings"

// goTestTimeoutPanic begins the line the Go test binary prints when its own timeout fires.
const goTestTimeoutPanic = "panic: test timed out after "

// EnvFailure is the environment failure of one check result: the host or the base made the
// check fail, not the candidate. Only a nonzero status with a line that, trimmed of
// surrounding whitespace, begins with the Go test binary's timeout panic qualifies; its text
// is the first such line, trimmed. Any other output, and a zero status, is none.
func EnvFailure(r CommandResult) (string, bool) {
	if r.Status == 0 {
		return "", false
	}
	for _, line := range strings.Split(r.Output, "\n") {
		if line = strings.TrimSpace(line); strings.HasPrefix(line, goTestTimeoutPanic) {
			return line, true
		}
	}
	return "", false
}

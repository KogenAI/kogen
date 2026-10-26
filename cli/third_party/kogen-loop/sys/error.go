package sys

import (
	"errors"
	"strings"
)

// Error is a refusal or failure shown to the user as `<class>/<reason>: <detail>`, followed
// by two-space-indented detail lines, with the process exit code (CLI-6).
type Error struct {
	Class, Reason, Detail string
	Lines                 []string
	Exit                  int
	// ProviderFailure holds allowlisted provider diagnostics for run records.
	ProviderFailure map[string]any
}

// Fail returns an *Error without detail lines.
func Fail(class, reason, detail string, exit int) *Error {
	return &Error{Class: class, Reason: reason, Detail: detail, Exit: exit}
}

func (e *Error) Error() string { return e.Class + "/" + e.Reason + ": " + e.Detail }

// Render is the error line and its detail lines, each ending in a newline.
func (e *Error) Render() string {
	var b strings.Builder
	b.WriteString(e.Error() + "\n")
	for _, l := range e.Lines {
		b.WriteString("  " + l + "\n")
	}
	return b.String()
}

// AsError returns the *Error in err's chain.
func AsError(err error) (*Error, bool) {
	var e *Error
	ok := errors.As(err, &e)
	return e, ok
}

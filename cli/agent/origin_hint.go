package agent

import (
	"slices"
	"strings"

	"kogen-loop/sys"
)

// OriginRelogin is the line that names the command a user runs after the loop refuses to
// send a saved OpenAI-compatible key to another origin.
const OriginRelogin = "log in again for that origin with: kogen provider login openai-compatible"

// WithOriginHint returns e with OriginRelogin added when it is the loop's refusal to send a
// saved OpenAI-compatible key to a different origin. The loop's own legacy-key errors already
// name the command, and any other error is returned unchanged.
func WithOriginHint(e *sys.Error) *sys.Error {
	if e == nil || e.Class != "provider" || e.Reason != "refused" || !strings.Contains(e.Detail, " key belongs to ") || slices.Contains(e.Lines, OriginRelogin) {
		return e
	}
	hinted := *e
	hinted.Lines = append(slices.Clone(e.Lines), OriginRelogin)
	return &hinted
}

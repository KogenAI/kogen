package claudecode

import (
	"strconv"
	"strings"
)

// Constraints is the entire task framing Kogen gives Claude Code besides the task itself
// (docs/executor-contract.md E8): it is round 1's prompt preface and, verbatim, the
// --append-system-prompt text. It prescribes no workflow, tools or subagents and does not copy
// Kogen's native builder prompt.
const Constraints = "You are implementing one requested feature in this Git checkout, the current directory. " +
	"Kogen will independently run the configured checks, an independent review and the single commit.\n" +
	"Do not commit, push, switch branches, stash or rewrite Git state.\n" +
	"Do not edit the protected paths named in the task: edits to them are refused, and any change to them is detected and stops the Build.\n" +
	"When you believe the work is complete, stop and summarize what you changed."

// feedbackPreface precedes Kogen's verification feedback in rounds after the first.
const feedbackPreface = "Kogen's independent verification of your previous round:"

// maxPromptBytes is a sanity bound on the prompt, which travels over the child's stdin and so has
// no argv size limit.
const maxPromptBytes = 16 << 20

// stripEnv is every variable removed from the child's environment: API keys, tokens,
// base-URL, cloud-provider and profile routes (they outrank the subscription sign-in) and the
// nested-session variables of a Claude Code that launched Kogen (audit section A).
var stripEnv = []string{
	"ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
	"CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
	"CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_PROFILE",
	// Cloud credentials and credential-file/profile selectors must not be inherited,
	// even when the corresponding Claude route selector has also been stripped.
	"AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AWS_SECURITY_TOKEN",
	"AWS_PROFILE", "AWS_DEFAULT_PROFILE", "AWS_SHARED_CREDENTIALS_FILE", "AWS_CONFIG_FILE",
	"AWS_WEB_IDENTITY_TOKEN_FILE", "AWS_BEARER_TOKEN_BEDROCK",
	"GOOGLE_APPLICATION_CREDENTIALS", "GOOGLE_CLOUD_ACCESS_TOKEN",
	"ANTHROPIC_FOUNDRY_API_KEY", "AZURE_CLIENT_SECRET", "AZURE_CLIENT_CERTIFICATE_PATH",
	"CLAUDECODE", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_ENTRYPOINT",
	"CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_SESSION_ATTENDED",
	"CLAUDE_PID", "CLAUDE_EFFORT", "CLAUDE_CODE_EXECPATH",
	// The effort override outranks --effort; Kogen passes the configured effort explicitly.
	"CLAUDE_CODE_EFFORT_LEVEL",
}

// setEnv is set in the child: no background work keeps `-p` open, no auto-memory writes under
// the user's ~/.claude.
var setEnv = []string{"CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1", "CLAUDE_CODE_DISABLE_AUTO_MEMORY=1"}

// childEnv is base minus the strip list, plus setEnv, and HOME when home is not empty.
func childEnv(base []string, home string) []string {
	drop := map[string]bool{"HOME": home != ""}
	for _, k := range stripEnv {
		drop[k] = true
	}
	for _, kv := range setEnv {
		drop[kv[:strings.IndexByte(kv, '=')]] = true
	}
	out := make([]string, 0, len(base)+len(setEnv)+1)
	for _, kv := range base {
		k, _, _ := strings.Cut(kv, "=")
		if !drop[k] {
			out = append(out, kv)
		}
	}
	out = append(out, setEnv...)
	if home != "" {
		out = append(out, "HOME="+home)
	}
	return out
}

// roundArgs is the exact argv (without the binary) for round n. There is no positional prompt:
// -p reads the prompt from stdin, which has no size limit (see session.runRound). Everything is
// passed again on every round: -p --resume restores neither the permission mode, --settings nor
// --mcp-config. Never --bare, --dangerously-skip-permissions, bypassPermissions or --continue.
func roundArgs(o Options, sessionID string, n int, model, effort, settingsPath string, maxTurns int) []string {
	args := []string{"-p"}
	if n == 1 {
		args = append(args, "--session-id", sessionID)
	} else {
		args = append(args, "--resume", sessionID)
	}
	if model != "" {
		args = append(args, "--model", model)
	}
	if effort != "" {
		args = append(args, "--effort", effort)
	}
	args = append(args,
		"--output-format", "stream-json", "--verbose", "--include-hook-events",
		"--permission-mode", "acceptEdits", "--permission-prompts", "none",
		"--allowedTools", "Bash",
		"--settings", settingsPath, "--setting-sources", o.SettingSources,
		"--strict-mcp-config", "--mcp-config", `{"mcpServers":{}}`,
		"--no-chrome",
		"--max-turns", strconv.Itoa(maxTurns),
	)
	if n == 1 {
		args = append(args, "--append-system-prompt", Constraints)
	}
	return args
}

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

// ShapeConstraints and ReviewConstraints frame the other two roles the same way: the entire
// framing besides the task itself, round 1's preface and the --append-system-prompt text.
const ShapeConstraints = "You are shaping one requested feature in this Git checkout, the current directory: you inspect it and propose the Intent files.\n" +
	"Kogen validates, checks and publishes your proposal; you cannot approve it, build it or commit it.\n" +
	"This checkout is read-only for you. Do not edit, create or delete any file, do not touch the Git index, and do not commit, push, switch branches, stash or rewrite Git state, including the files you propose: submit them instead.\n" +
	"Finish with the structured submission the schema requires, as your final result."

const ReviewConstraints = "You are the independent reviewer of one candidate in this Git checkout, the current directory. " +
	"Kogen will independently run the configured checks and the single commit.\n" +
	"You may repair concrete defects within the approved Intent. Do not commit, push, switch branches, stash or rewrite Git state.\n" +
	"Do not edit the protected paths named in the task: edits to them are refused, and any change to them is detected and stops the Build.\n" +
	"Finish with the structured review verdict the schema requires, as your final result."

// constraintsFor is the framing of a role.
func constraintsFor(role string) string {
	switch role {
	case "shape":
		return ShapeConstraints
	case "review":
		return ReviewConstraints
	}
	return Constraints
}

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
	// Set by Kogen only together with a stored token.
	"CLAUDE_CODE_SUBPROCESS_ENV_SCRUB",
}

// setEnv is set in the child: no background work keeps `-p` open, no auto-memory writes under
// the user's ~/.claude.
var setEnv = []string{"CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1", "CLAUDE_CODE_DISABLE_AUTO_MEMORY=1"}

// childEnv is base minus the strip list, plus setEnv, HOME when home is not empty and
// CLAUDE_CODE_OAUTH_TOKEN (with CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1) when a stored token is given
// (the strip list always applies first).
func childEnv(base []string, home, token string) []string {
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
	if token != "" {
		out = append(out, "CLAUDE_CODE_OAUTH_TOKEN="+token)
		// Claude Code must not hand the token on to the processes it runs (Bash tool, hooks).
		out = append(out, "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1")
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

// roleRoundArgs is roundArgs for a role. Build is exactly roundArgs. Shape and Review frame the
// task with their own constraints and request schema-constrained output (--json-schema) on every
// invocation, the first with --session-id (never --resume, --continue or --fork-session) and
// later feedback rounds of the same role session with --resume.
func roleRoundArgs(o Options, role, schema, sessionID string, n int, model, effort, settingsPath string, maxTurns int) []string {
	args := roundArgs(o, sessionID, n, model, effort, settingsPath, maxTurns)
	if role == "" || role == "build" {
		return args
	}
	for i, a := range args {
		if a == "--append-system-prompt" && i+1 < len(args) {
			args[i+1] = constraintsFor(role)
		}
	}
	return append(args, "--json-schema", schema)
}

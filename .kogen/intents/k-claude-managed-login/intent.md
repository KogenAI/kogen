# Sign in to Claude with Kogen's managed runtime

Slug: k-claude-managed-login
Model: not applicable — the change wires an existing sign-in into one command and updates text; it adds no state machine
Acceptance:
- .kogen/intents/k-claude-managed-login/acceptance.feature
- features/steps/k-claude-managed-login__steps.js

On a fresh install `kogen provider login claude-code` could not sign in with Kogen's own runtime: the runtime is installed only at the first role that needs it, `kogen init` does not download it, and a role needs a saved token first. On an interactive terminal (stdin and stdout both terminals), `kogen provider login claude-code` now calls the already-consumed `claudecode.SetupToken(ctx, home, out)` from `github.com/KogenAI/kogen-executor/executor/claudecode`. That installs or uses Kogen's pinned runtime under the managed config directory (CLAUDE_CONFIG_DIR isolation as now) and obtains a subscription token, which the command stores through the existing private token-store path (private file mode). `kogen init` stays unchanged and does not download the runtime. When a token is piped on stdin, behavior is unchanged: the token is stored, with no runtime install and no sign-in. If install or sign-in fails, any already-saved credential is left byte-identical, the command exits non-zero with retry guidance (for example `run kogen provider login claude-code to retry`), and the token value is never printed or logged. `cli/go.mod`, `cli/go.sum` and dependencies stay unchanged. `kogen provider login --help` (cli/help.go, and the `login claude-code` line in the top-level usage in cli/main.go) and docs/getting-started.md describe the interactive sign-in and the piped path as storage only, and no longer tell users to run the runtime's `setup-token` by hand; the sentence saying provider login never downloads the runtime is corrected. Provider-list behavior is not touched.

## Decisions
- Terminal detection uses both stdin and stdout being terminals; the Go tests inject a fake SetupToken through a package-level seam in cli, since the real one needs network and a browser. (evidence: cli/native.go; cli/main.go) (assumption: a package-level function variable is an acceptable test seam) (source: request)
- The token store used is the existing one that the piped path already uses; the Build locates it from the current login code. (evidence: cli/native.go) (source: request)
- Acceptance drives the real binary for the piped path, help, docs and pins; the terminal and failure paths need a fake seam and a terminal, so they are Go tests the Build adds in cli. (evidence: cli/login_installed_test.go; cli/pty_linux_test.go) (assumption: acceptance cannot reach the in-process seam, so the terminal and failure checks live in Go tests) (source: request)
- Help and docs must contain the phrases `interactive terminal` and `piped`, state that piped input is storage only (`storage only`), and must not contain `setup-token`. (evidence: cli/help.go; docs/getting-started.md) (source: request)

## Source comparison
- Addressed: terminal path calls SetupToken once and stores its token privately (Go test, Tests line 1).
- Addressed: piped path unchanged, no runtime directory (acceptance scenario 1).
- Addressed: failure leaves saved token byte-identical, non-zero exit, retry guidance, no token in output (Go test, Tests line 3).
- Addressed: help and docs (scenarios 2 and 3); go.mod/go.sum unchanged (scenario 4).
- Addressed: `kogen init` keeps not downloading the runtime; CLAUDE_CONFIG_DIR isolation is kept as now.
- Omitted: the fresh-home real browser handoff, done after delivery outside this Build.

## Tests
- Terminal mode calls SetupToken once and stores its token with private mode: Go test in cli with a fake SetupToken seam and pseudo-terminal or injected terminal flag (integration)
- Piped mode stores the token, skips SetupToken, creates no runtime directory: acceptance scenario 1 plus a Go test asserting the fake is not called (scenario)
- Failure keeps a pre-existing saved token byte-identical, exits non-zero with retry guidance, never prints the token: Go test with a failing fake (integration)
- Help text and guide describe interactive sign-in and storage-only piped path: acceptance scenarios 2 and 3 (scenario)
- go.mod and go.sum unchanged: acceptance scenario 4 (scenario)
- Existing offline suite stays green: go test ./... in cli (existing)

## Feasibility
- none

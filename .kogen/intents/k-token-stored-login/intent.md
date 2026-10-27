# Use a stored token for the Claude Code executor

Slug: k-token-stored-login
Model: not applicable — credential plumbing with no state machine
Acceptance:
- .kogen/intents/k-token-stored-login/acceptance.feature
- features/steps/k_token_stored_login_steps.js

Kogen's Claude Code executor (`cli/executor/claudecode`) can use a long-lived Claude Code subscription token made with `claude setup-token`, so no interactive `claude auth login` is needed. The inherited-credential strip list (`stripEnv` in `args.go`) and its reason (inherited API keys or tokens must not silently outrank the chosen subscription route) stay unchanged, including removal of an inherited `CLAUDE_CODE_OAUTH_TOKEN`.

**Login.** `kogen provider login claude-code` reads one token from stdin (or an echo-suppressed terminal, like `kogen provider login anthropic`), trims surrounding whitespace, and refuses empty input or a token that still contains whitespace or control characters (so multi-line input is refused) with a clear message that never includes the input. No network call. It saves `~/.kogen/credentials/claude-code.json` (file 0600, directory 0700, same locking and atomic write as the other providers); a second login replaces the token. Never printed. `kogen provider list` shows `claude-code: token saved (not verified)` when saved. `kogen uninstall`'s kept-logins message (including `claude-code.json` and its `.lock`), the zsh completion provider list, the unknown-provider usage list and help text include `claude-code`. Add `kogen provider logout claude-code` only if logout already exists for other providers, following that pattern; otherwise do not add a command.

**Child environment.** `childEnv` still removes everything in `stripEnv` first. When a stored token exists, the adapter then sets `CLAUDE_CODE_OAUTH_TOKEN=<stored token>` in the child environment, only from the store (the real user home, not the child HOME override), for both `claude auth status --json` and the run. With no stored token behaviour is exactly as today.

**Auth check.** With a stored token, `claude auth status --json` runs with that environment and the result Claude Code reports for token auth is accepted when it is a signed-in, first-party (`firstParty`) subscription route (`claude.ai`, or the token-auth method name Claude Code reports); API-key, Bedrock, Vertex, Foundry and other non-subscription routes are still refused. `executor_started` records only auth method/provider/plan, never the token. If the stored token is rejected (not signed in under it), fail with `executor/auth_refused` and a message telling the user to run `claude setup-token` and `kogen provider login claude-code`. Without a stored token the existing message stays.

**No token elsewhere.** The token is never in argv, logs, run records, transcripts, checkpoints, readiness or inspect output, or error text; add it to any existing secret-redaction list.

**Docs.** README, `docs/configuration.md` (Claude Code executor section) and `docs/executor-contract.md` explain making a token with `claude setup-token`, saving it with `kogen provider login claude-code` (stdin), that it takes precedence over a stored `claude auth login`, that inherited environment tokens are still ignored, and how to remove it (`rm -f ~/.kogen/credentials/claude-code.json ~/.kogen/credentials/claude-code.lock`, or logout if it exists). `docs/configuration.md` names `claude-code.json`. Spec prose where the executor's auth is described is updated; the spec checks keep passing.

Unchanged: other providers, request bytes, transcripts, checkpoints, resume, review custody, the single commit, timeouts and limits. Tests use synthetic tokens only.

## Decisions
- Token shape is validated offline as: nonempty after trim, no whitespace or control characters; no prefix is enforced (source: request)
- A stored token takes precedence over a stored `claude auth login`; with none stored, behaviour is as today (source: request)
- Logout follows the existing pattern only if it exists (source: request)

## Source comparison
- Login command, 0600/0700 store, offline list line `claude-code: token saved (not verified)`, uninstall and completion: addressed in intent prose and acceptance scenarios 1-3 (uninstall/completion in Go tests).
- Child env precedence over inherited token and strip list preserved: addressed by acceptance scenario 4 and 5.
- Auth check, `executor/auth_refused` hint and non-subscription refusal: addressed by scenario 6 and Go tests; non-subscription refusal kept by existing tests.
- No token elsewhere / grep of run directory: addressed by scenarios 4 and 6 grep steps; the fake reports claude.ai/firstParty for accepted tokens (the exact method name real Claude Code reports for token auth is unverified; the adapter also accepts the token-auth name it reports).
- Docs: addressed by the documentation scenario.
- No network at login, no new timeout/limit, no change to other providers: stated as boundaries.

## Tests
- Login validation, trimming, private store, replacement, list line: acceptance scenarios 1-3 (scenario)
- Login rejects empty/whitespace tokens: unit test in the provider credential package plus scenario 3 (unit)
- Child env sets stored token, strips inherited and other variables: Go test in `cli/executor/claudecode` extending the `childEnv` tests, plus scenario 4 (unit)
- No stored token ignores inherited token and is refused: scenario 5 and existing adapter tests (scenario)
- Token auth accepted, non-subscription routes still refused, rejected token hint, `executor_started` omits the token: Go adapter tests (unit)
- Token redaction everywhere: scenario 4 and 6 grep (scenario)
- Uninstall message, zsh completion and usage include claude-code: update `cli/completion_test.go`, `cli/parse_test.go` and uninstall tests (unit)
- Documentation: scenario 7 (scenario)

## Feasibility
- none

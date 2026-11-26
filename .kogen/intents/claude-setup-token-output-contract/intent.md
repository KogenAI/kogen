# Test Claude setup-token output redaction

Slug: claude-setup-token-output-contract
Model: not applicable — this change adds tests without changing the screen's state transitions.
Acceptance:
- .kogen/intents/claude-setup-token-output-contract/acceptance.feature
- features/steps/claude-setup-token-output-contract__steps.js

Add focused, same-package Go tests in `cli/internal/claudecode/setup_token_test.go` for the production screen handling in `cli/internal/claudecode/setup_token.go`. No production behavior or existing login test is replaced. Keep the tests local and deterministic: no real browser sign-in, network access, or runtime installation.

## Decisions
- Preserve the documented `SetupToken(ctx context.Context, home string, out io.Writer) (string, error)` guarantee: the token is returned but never written to output or an error. Add coverage at the stdout writer and parser, not by invoking login. (evidence: cli/internal/claudecode/setup_token.go; cli/login_claude_managed_test.go) (source: request)
- Test the observable bytes forwarded by `tokenScreen.Write([]byte) (int, error)` with an in-memory destination. From the first `Your OAuth token` marker onward, no marker, token text or later bytes are forwarded. Bytes before the marker are still forwarded, even if the first part of the marker shares a write with the prompt. (evidence: cli/internal/claudecode/setup_token.go) (source: request)
- Test `parseSetupToken(stdout string) string` with a synthetic success screen and missing-marker and missing-token screens. The token is on a line following the marker line; assert the exact trimmed token, or `""` when either the marker or token is absent. Do not assert hidden state or add new parser rules. (evidence: cli/internal/claudecode/setup_token.go) (source: request)

## Source comparison
- Addressed, `ev-143f67a5`: `SetupToken` documents return-only token handling and the login tests substitute a mock. This contract adds direct tests of the production stdout writer and parser; it leaves caller tests and production behavior intact.
- Addressed, acceptance 1 and its counterexample: “A split marker and split token never reach forwarded output” exercises tests that must catch both single-write-only marker detection and loss of the pre-marker text.
- Addressed, acceptance 2 and its counterexample: “A whole marker hides its token and all later writes” requires tests that catch forwarding the payload after a whole marker within the same write as well as resuming forwarding later.
- Addressed, acceptance 3 and its counterexample: “Only trimmed token text after the marker is returned” requires tests that catch an untrimmed return, acceptance of arbitrary markerless text and any nonempty result for a missing token.
- Omitted by requested scope: real browser sign-in, network access and runtime installation. No new CLI error-path test is required: the return-only guarantee is preserved, and the direct test gap requested here is the screen's forwarded stdout and token parsing. Nothing is superseded or conflicts with the request.

## Tests
- Split marker and split token: write a prompt ending in the start of the marker, the rest of the marker and the first part of the fake token, and the rest of the token separately; compare forwarded output with just the prompt (unit)
- Whole marker and persistent withholding: write the whole marker and fake token together, then additional nonempty text; compare output with just the prompt after the marker write and after the later write (unit)
- Trimmed token after marker: compare the parser result with the exact token, without surrounding whitespace (unit)
- Missing marker or token: assert an empty parser result for markerless text and for a marker with no token (unit)

## Feasibility
- The repository's Go 1.27.2 package tests pass with module downloads disabled. The compiled test binary reports `--- PASS: TestUnsupportedMessage` and `PASS` (local probe, exit 0). The acceptance observer builds only `./internal/claudecode` with `go test -trimpath -c` and runs the binary verbosely without requiring any new test name. It uses temporary Go overlays for deliberate mutations; a compile error, crash or timeout is not proof of a test assertion. Keep the configured checks unchanged. (evidence: cli/go.mod; .kogen/project.yaml)
- The observer controls compile real tests with adequate and deliberately incomplete coverage. They exercise all seven checks independently, including the assertions a baseline failure can skip. The controls are scratch fixtures; Build adds the production test file, and acceptance uses that file's actual tests.
- evidence: {"id":"setup-token-coverage-observer","kind":"observer","inputs":[".kogen/intents/claude-setup-token-output-contract/controls.json","cli/internal/claudecode/setup_token.go"],"observers":["features/steps/claude-setup-token-output-contract__steps.js"],"checks":[{"name":"good","command":"node features/steps/claude-setup-token-output-contract__steps.js good","exit":0,"output":"Setup-token coverage detected 7 of 7 targeted mutations.\n"},{"name":"bad","command":"node features/steps/claude-setup-token-output-contract__steps.js bad","exit":1,"output":"Setup-token coverage detected 0 of 7 targeted mutations.\n"}]}

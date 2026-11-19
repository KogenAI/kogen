# Update Claude Code daily after a hook self-test

Slug: claude-code-daily-update-after-hook-self-test
Model: not applicable — the change is a check-and-switch of an installed executable verified through the CLI, with no state machine worth modelling
Acceptance:
- .kogen/intents/claude-code-daily-update-after-hook-self-test/acceptance.feature
- features/steps/claude-code-daily-update-after-hook-self-test__steps.js

Kogen keeps running its pinned Claude Code 2.1.318 (`~/.kogen/claude-code/2.1.318/claude`) unless a newer version has passed Kogen's own hook self-test. Before the first Claude Code child of any role start (Shape, Refine, Build, Review, resume) Kogen reads `~/.kogen/claude-code/harness.json`; when `checked_at` is missing or more than 24 hours old it runs one check and writes `checked_at` when the check ends. `kogen provider update claude-code` runs the same check immediately whatever the age. A check never stops or delays a role beyond its 60 second lookup limit: an unreachable origin, a malformed answer or a timeout records the reason in harness.json and leaves the active version unchanged.

Lookup: one GET of `latest` under `https://downloads.claude.ai/claude-code-releases` (in tests only, the existing loopback origin `KOGEN_CLAUDE_CODE_URL`), whose body is a version such as `2.1.319`. A version equal to or older than the active one, or already recorded as failed, ends the check as unchanged with no download.

Install: a newer version is downloaded into its own version directory through the existing locked partial-directory install, checked against the size and SHA-256 of `<origin>/<version>/manifest.json` (platforms `darwin-arm64`, `linux-x64`), and run once with `--version`, whose first field must be that version. Older version directories are never changed or removed.

Self-test (a throwaway checkout, the executor's real argument list, hook settings and hook policy with a protected file, a loopback stand-in for the model service inside Kogen, a throwaway token, its own temporary configuration directory; the saved Claude Code token is never given to the candidate): the stand-in scripts one new-file write, one edit of an existing file and one write to the protected file. The candidate passes only when every guarded call that ran has a PreToolUse record in the hook log, the allowed writes happened, and the protected write was refused by the hook (deny record, the call reported as an error, file unchanged). The failing checks read `guarded call ran without a hook record` and `protected edit was not refused`.

Outcome: on a pass Kogen writes the version into `~/.kogen/claude-code/active` and prints `kogen: Claude Code 2.1.319 passed Kogen's hook self-test; now active (was 2.1.318)`. The next Build then runs `~/.kogen/claude-code/2.1.319/claude`, the 2.1.318 directory stays installed and unchanged, and `kogen provider list` shows `claude-code runtime: Claude Code 2.1.319 installed (~/.kogen/claude-code/2.1.319/claude)` with the real home path. Role starts use the version in `active` when that directory holds a runtime whose `--version` first field matches, otherwise the compiled pin 2.1.318. On a fail Kogen removes the candidate directory, records the version as failed in harness.json, prints `kogen: Claude Code 2.1.319 failed Kogen's hook self-test (<failing check>); staying on 2.1.318` and keeps the active version; a failed version is never downloaded again, a later newer one is checked normally. A running role keeps the executable it started with.

Receipt: each Build attempt's result.json gains `claude_code_version` (first field of the `--version` answer of the executable that actually ran the Build attempt's builder) and `claude_code_source` (`pinned` for the compiled pin, `updated` when it came from `active`).

This replaces the rule that no manifest is read and nothing selects another version. Scope: the Go packages under cli/ that resolve, install and run Kogen's Claude Code and write the Build result, the new command, and the spec text in spec/prose/04-building.md (LOOP-15) and spec/reference/configuration-details.md (Managed runtime and Installation), which must state the new rule instead of the replaced one. `kogen uninstall` also removes the new files (they live in the Claude Code directory). Other executors, providers, timeouts, retries, login commands and uninstall behavior are unchanged. No other documents are in scope.

## Decisions
- The stand-in model service answers every `POST /v1/messages` with the Anthropic streaming (SSE) wire format, one scripted turn per request: Write of a new file, Edit of an existing file, Write of the protected file, then a final text turn; tool paths are absolute paths in the throwaway checkout. It is passed to the candidate as `ANTHROPIC_BASE_URL` (`http://127.0.0.1:<port>`) with the throwaway token in `ANTHROPIC_AUTH_TOKEN`; the candidate gets neither the managed `config` directory, `CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR` nor the saved token. (decision: D1, round 1) (assumption: the acceptance candidate speaks this wire format; real Claude Code compatibility with it was not probed) (source: request)
- harness.json is a JSON object: `checked_at` (RFC 3339 UTC string), `last_result` (string; it starts with `unreachable` for an unreachable origin, a malformed answer or a timeout is recorded the same way with its own reason) and `failed` (object whose keys are failed versions and whose values are the failing check text). `active` holds the version text. (decision: D2, round 1) (assumption: field names are chosen by this Intent; the request only names checked_at) (source: request)
- Each Build attempt's receipt names the executable that ran its builder, read from that executable's own `--version` answer at the role start, so an update completed while the Build runs does not change that Build's receipt. (decision: D3, round 1) (evidence: spec/prose/04-building.md) (source: request)
- The acceptance drives the shipped Kogen through the existing loopback origin seam and the repository's fake Claude Code; an update run by the pinned runtime inside its first Build round models a Build started before an update. The scenarios are merged so the whole feature runs few Builds inside the acceptance time limit. (decision: D4, round 1) (evidence: features/steps/k_managed_claude_steps.js; test/acceptance/fixtures/claude/fake-claude.js) (source: request)

## Source comparison
- addressed: cadence, lookup, install, self-test, outcome, receipt and scope of the request; its acceptance checks 1-5 map to the scenarios of acceptance.feature (check 5's pinned and updated receipts are asserted inside the 23 hour and the working-candidate scenarios).
- superseded: the LOOP-15 and configuration-details statements "no manifest is read, `latest` and `stable` are never asked for and nothing selects another version".
- unchanged: the pinned 2.1.318 install from the compiled pin, `kogen provider login claude-code`, other executors and providers.

## Tests
- A newer working candidate becomes active, older directory untouched, next Build, its receipt and provider list use it: scenario "A candidate whose hooks work becomes active and runs the next Build" (scenario)
- A candidate without hook records is refused, removed, recorded failed and never downloaded twice: scenario "A candidate that never runs the hook for guarded writes is refused and not downloaded again" (scenario)
- A candidate that allows the protected write is refused: scenario "A candidate whose hook allows the protected write is refused" (scenario)
- 24-hour cadence, one lookup, none at the next start, pinned receipt: the 23 hour and 25 hour scenarios (scenario)
- Unreachable origin never stops a role: scenario "An unreachable origin never stops a role" (scenario)
- A running Build keeps its version: scenario "A Build started before an update keeps the version it started with" (scenario)
- Spec text states the new rule: the configured spec check runs against the edited spec text (existing)

## Feasibility
- none

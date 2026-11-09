# Make Claude Code token route non-circular

Slug: claude-code-token-route-not-circular
Model: not applicable — listing and documentation do not change a state machine
Acceptance:
- .kogen/intents/claude-code-token-route-not-circular/acceptance.feature
- features/steps/claude-code-token-route-not-circular__steps.js
- features/steps/claude-code-token-route-not-circular__doc/route.js

Replace the circular instruction in docs/getting-started.md with the ordinary Claude Code token route. The missing runtime path on a fresh install causes exit 127; Kogen installs its runtime at the first Claude Code role that needs it, which needs a saved token. Explain that the runtime path exists only after a Claude Code role such as Build or Refine installs it. Keep the rest of the guide, correcting its list excerpt.

The default text `kogen provider list` shows a Claude Code login line and runtime line on every home, whether a token is saved or the runtime is installed. Preserve existing provider ordering, compatibility text, offline behavior, JSON, authentication, redaction, installation semantics and pins. Correct the adjacent contradictory conditional status description in docs/configuration.md and update affected tests and specifications. Do not edit protected paths.

The existing offline installation witness from cli is `go test github.com/KogenAI/kogen-executor/executor/claudecode -run '^Test(PinTable|InstallsThePinnedRuntime|InstalledRuntimeIsNeverReplaced|OlderVersionDirectoryIsUntouched)$' -count=1`; the acceptance helper adds verbose output to verify every named test ran.

## Decisions
- Print the existing saved-but-unverified Claude Code status when a token is saved, otherwise a not-signed-in line, after the provider lines; preserve the runtime status format and put it after that line. (evidence: cli/native.go; cli/third_party/kogen-loop/provider/creds.go) (source: request)
- Use the repository's current runtime pin rather than changing it to the historical example version in the issue. (evidence: cli/claude_runtime_test.go; docs/getting-started.md) (source: request)
- Use a synthetic saved token and a local regular runtime file in isolated homes, without live authentication or downloads. (evidence: cli/claude_runtime_test.go) (source: request)
- The default listing includes both a Claude Code login line and a runtime status line on every home. (assumption: the user accepts showing both lines in every state) (source: request)
- The exact positive sentence in acceptance is the selected wording for the getting-started route. (assumption: the user accepts this concise wording) (source: request)

## Source comparison
- Addressed: the issue's fresh-home invisibility and exit-127 circular route are covered by the provider-list and getting-started scenarios and the outcome above.
- Addressed: the saved-token and installed-runtime states are covered separately and together by acceptance.feature.
- Superseded: the issue's example version 2.1.312 is not a version change; retain the repository pin 2.1.318 as asserted by the runtime scenarios and existing offline tests.
- Addressed: the requested ordinary Claude Code setup-token and stdin login order is given in the exact positive sentence in acceptance.feature; the getting-started guide otherwise remains intact apart from the affected excerpt, as checked against the baseline.
- Addressed: immutable dependency lifecycle tests verify pinned installation, reuse and preservation of older runtime directories, without a live service or credential.
- Conflicting: docs/configuration.md describes runtime status as conditional on a token or folder; correct that description to reflect every home without changing its other details.
- Omitted: other guides and their optional runtime-based routes are outside the requested getting-started correction.

## Tests
- Fresh home exposes Claude Code and runtime status without creating the runtime folder: exercise default provider list on a fresh isolated home (regression)
- Saved token and installed runtime are represented in all requested states with the unchanged pin: exercise provider list with synthetic token and fake installed file (scenario)
- JSON listing remains unchanged: exercise JSON provider list and existing coverage (existing)
- The guide names the working order and runtime timing and removes the circular instruction: inspect the changed guide (scenario)
- The rest of the getting-started guide remains intact: compare unaffected content against the original guide (existing)
- Pinned installation and runtime lifecycle remain unchanged: run the existing offline executor runtime lifecycle tests and verify each named result (existing)

## Feasibility
- evidence: {"id":"doc-route-observer","kind":"observer","inputs":[".kogen/intents/claude-code-token-route-not-circular/acceptance.feature",".kogen/intents/claude-code-token-route-not-circular/route-good.md",".kogen/intents/claude-code-token-route-not-circular/route-bad.md"],"observers":["features/steps/claude-code-token-route-not-circular__doc/route.js"],"checks":[{"name":"good","command":"node features/steps/claude-code-token-route-not-circular__doc/route.js .kogen/intents/claude-code-token-route-not-circular/route-good.md .kogen/intents/claude-code-token-route-not-circular/acceptance.feature","exit":0,"output":"working route found\n"},{"name":"bad","command":"node features/steps/claude-code-token-route-not-circular__doc/route.js .kogen/intents/claude-code-token-route-not-circular/route-bad.md .kogen/intents/claude-code-token-route-not-circular/acceptance.feature","exit":1,"output":"working route missing\n"}]}

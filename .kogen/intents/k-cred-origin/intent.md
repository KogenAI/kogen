# Bind compatible login keys to user input origins

Slug: k-cred-origin
Model: not applicable — plain CLI wiring of the pinned loop's existing credential-origin state machine introduces no new state
Acceptance:
- .kogen/intents/k-cred-origin/acceptance.feature
- features/steps/k_namedfeedback_steps.js

Change only `kogen provider login openai-compatible` to read a user-supplied base URL line, then a private API-key line, from stdin or terminal, prompting exactly `Base URL:` then `API key:`. Pass the URL to pinned `Client.LoginWithBaseURL`. Never obtain this login URL from `.kogen/project.yaml` or any repository file. Preserve every other login byte-for-byte through `Client.Login`, including prompts, input and errors. Add no command, subcommand or flag. Do not edit `cli/third_party/kogen-loop/**` or `cli/loop-pin.json`, already pinned to c6e67a5.

Read one continuous input stream without losing an already-buffered piped key line. Preserve the loop's private terminal key input and terminal restoration. Surface existing provider origin errors for mismatches and legacy unbound keys with a hint to run `kogen provider login openai-compatible` again, before any request. The loop owns normalization, HTTPS saved-key validation and keyless local HTTP policy; do not recreate or broaden those policies.

Update CLI help, docs/configuration.md, spec/prose/08-chatgpt.md, help in spec/prose/09-cli-and-process.md and applicable spec scenarios/steps in this commit. Explain URL-first/key-second input, repository-independent user URL, HTTPS saved keys, origin binding and re-login for legacy or different-origin keys. Preserve keyless localhost examples without login. Restore openai-compatible in cli/login_installed_test.go TestInstalledKeyLoginUnderPipesAndATerminal, supplying the base URL first in piped and terminal drivers while retaining all private-key, invalid UTF-8, signal and restoration assertions and other providers' cases.

Tests below must exercise actual behavior, not inspect private call structure. For origin request tests use the credentials saved by actual CLI login and the real role/provider request path with deterministic local transport; no external requests. A matching https://a.example/v1 role must send Bearer KEY and succeed; a https://b.example/v1 role must fail before transport. Assert compatible installed subtests really execute, not merely the parent test passing.

## Decisions
- Prompt exactly `Base URL:` then `API key:` from the same input source (source: request)
- Add no commands or flags and preserve every other login (source: request)
- Origin mismatches and legacy keys produce an explicit re-login hint (source: request)

## Source comparison
- Addressed: K-CRED-ORIGIN input order, exact prompts, repository independence and LoginWithBaseURL are specified above and covered by TestCompatibleLoginUserOrigin.
- Addressed: request acceptance literal https://a.example/v1 followed by KEY, stored origin https://a.example, matching role success and https://b.example/v1 pre-request rejection are preserved in acceptance.feature and the named regression contracts.
- Addressed: legacy credentials, re-login hints, installed pipe/terminal privacy, unchanged other providers, no command/flag additions, same-commit help/docs/spec and all configured checks are explicit obligations above and below.
- Addressed: shared-host safety requires temporary fixture homes only, no real credential reads, no synthetic CPU load and killing only owned child pids.
- Superseded: URL-less compatible login and key-only stdin documentation. Other login behavior remains unchanged.
- KS-1 describes the historical global-key leak; origin remediation is already in pinned c6e67a5. Broader transport-policy changes from the audit are deliberately omitted because this request only wires existing pinned policy into login. Vendored paths and pin remain untouched.

## Tests
- URL-first piped login and repository independence: add TestCompatibleLoginUserOrigin through the real CLI using fixture HOME, conflicting repository URL, input https://a.example/v1 then KEY, exact ordered prompts and saved JSON origin/api_key assertions (regression)
- Matching and mismatching role origins: add TestCompatibleLoginRoleOrigins proving matching origin succeeds with Bearer KEY while the different origin fails before transport with origin error and re-login command (integration)
- Legacy unbound credentials: add TestCompatibleLoginLegacyOriginHint using fixture provider/api_key JSON without origin, asserting no request and existing error plus re-login command (regression)
- Installed private input: restore compatible cases in TestInstalledKeyLoginUnderPipesAndATerminal with URL first, invalid UTF-8 preservation and terminal success/empty/SIGINT/SIGTERM/SIGHUP restoration coverage (scenario)
- Help docs and spec reflect two-line origin-bound login: add TestCompatibleLoginContractText checking real help output and updated documentation/spec examples and update applicable spec CLI scenarios (scenario)
- Other providers and configured checks remain unchanged: retain existing login tests and run all configured checks (existing)

## Feasibility
- none

# Prepare the kogen tree for public readers

Slug: k-public-ready-kogen
Model: not applicable — documentation and record text changes only; no state, transitions or program behaviour change
Acceptance:
- .kogen/intents/k-public-ready-kogen/acceptance.feature
- features/steps/k_public_ready_kogen_steps.js

kogen is the public repository https://github.com/KogenAI/kogen. Its tree was written while private. After this change a public reader finds a README that says what this repository is and how to set it up and test it from a plain clone, every Markdown link resolves publicly, and no file outside the out-of-scope set carries a runner or home path, a host name or the owner's personal name. Program behaviour does not change: every configured check passes unchanged and no assertion is weakened. Git history is never rewritten; its hits are listed at the end of this prose for the owner to decide on.

What counts as a hit is exactly what `features/steps/k_public_ready_kogen_steps.js` scans: every tracked file and every new file Git does not ignore, read as text (files with a NUL byte in their first 8192 bytes are skipped), except `.kogen/project.yaml`, `cli/third_party/kogen-loop/`, `cli/loop-pin.json`, `cli/go.mod` and `cli/go.sum`. Kinds: home path (`/Users/<name>/` or `/home/<name>/` as an absolute path; a segment starting with `<` is a placeholder and is allowed), runner path (a host work or scratch folder carrying the macOS no-index folder suffix, or a real macOS per-user temporary path under `/var/folders/...`), host name (the build-host names, including the short alias of the bench host, and a `*-MacBook-Pro` machine name on `.local`), personal name (the owner's first name or surname, in any case, including inside an e-mail address). The step file keeps the names ROT13-encoded so that it does not carry them itself; a failing run prints every remaining hit as `file:line kind: excerpt`. At this HEAD the hits are in 58 files: existing Intent records under `.kogen/intents/`, `docs/evidence/bundled-zip-safety/receipts/runtime.txt` and five step files.

Replace each hit with a neutral placeholder and keep everything else the record says (no record, sentence or evidence reference is deleted):
- a home-directory prefix `/Users/<name>` or `/home/<name>` becomes `<home>`, keeping the rest of the path (for example `<home>/src/loop-1b8ef1f`, `<home>/Areas/Kogen/studio-work/...`, `MIX_HOME=<home>/.mix`); this is the convention `docs/` already uses;
- a path into a host work or scratch folder with the no-index suffix, whether written from the home directory, from `~/` or from a home path, becomes `<work>` up to and including that folder, keeping the rest (for example `<work>/k-go-test-parallel-5308fb40.diff`, `<work>/src/s-browser-waits/...`, `<work>/kogen-lanes-private/...`);
- a macOS per-user temporary path keeps its `/var/folders/...` shape with the per-user part replaced by `...` (for example TMPDIR `/var/folders/.../T/`);
- a host name, its short alias or a machine name becomes `<host>` (for example `(laptop <host>, kogen 5d93641`, `retrieval from <host>:~/logs/...`, `Evidence on <host>:`, `Darwin <host> 25.6.0`);
- the owner's personal name in prose becomes "the owner" ("The owner" at a sentence start, "the owner's" for the possessive), for example `except the two changes the owner approved:` and `The owner, 22 October 2026 (exact user message):`; the owner's e-mail address in prose becomes `<owner-email>`.

Step files are part of the records whose `Acceptance:` lists them; they change only where a hit is, and stay consistent with their records:
- `features/steps/build_continuity_steps.js` and `.kogen/intents/build-continuity/acceptance.feature` share the HTML title suffix literal: the name in it becomes `Owner` in both (`— Owner Δ🙂`, `label: 'Keep exactly — Owner Δ🙂'`, `JSON.stringify(r.answers).includes('Owner')`);
- `features/steps/all_provider_cache_steps.js` uses the owner's e-mail address as its fixture Git identity in three places (the fixture `.gitconfig`, the commit-msg hook assertion and the `identities` check); all three become the synthetic `cache-fixture@example.invalid`;
- `features/steps/k5_loop_repin_steps.js` (`DEFAULT_SOURCE`), `features/steps/native_image_evidence_steps.js` (`retainedEvidence` dir) and `features/steps/supergrok_subscription_steps.js` (`PRECHECK`) name owner-only retained-evidence locations under the home directory; each becomes `path.join(os.homedir(), '<the same remainder>')` (adding `const os = require('node:os');` where the file lacks it), so every machine reads the same location as before.
Where any other record's steps compare a replaced literal by exact text, length or hash, keep both sides consistent. Historical Intent acceptance suites are records and are not rerun by the configured checks.

README.md changes, keeping the rest of the product description:
- Before its first `## ` heading it says that this repository is `kogen`, the command-line program that is Kogen's small core (taking one requested feature through Shape, Build, Verify, Review and Commit in your own Git repository), and links https://kogen.dev for Kogen as a whole.
- Its setup and test steps start from a plain public clone: `git clone https://github.com/KogenAI/kogen` and `cd kogen`, the toolchain from `.tool-versions` (Go and Node), the existing `npm ci` steps and a Go test command containing `cd cli && go test` (the existing `(cd cli && go test -race ./...)` qualifies). The component modules in `cli/go.mod` are public Go modules on github.com/KogenAI and need no setup; nothing about private modules, mirrors or tokens is added.
- Removed: both parenthetical `(Studio Build 543748f1)` references; the internal issue id in "of KOGEN-057" (the link to `docs/model-family-qualification.md` stays); the sentence saying that the 24 October migration candidate took 516.8 seconds under concurrent local work; the claim "There is no published release yet: you build the release archive from this repository." (development prereleases are published at https://github.com/KogenAI/kogen/releases and `packaging/install-kogen.sh` installs them; building from source stays documented).
- `contact@kogen.dev` appears exactly once, in the Contact section.
- It keeps the sentence part "reads the key's base URL line, then the key line", which `cli/compatible_login_test.go` asserts.
- It mentions no contribution policy or refusal, no maintenance promise, and nothing about issues or pull requests being disabled.

Other documentation:
- `docs/configuration.md`: remove the "Issue attribution: DELIVERY-20261018 ..." paragraph that points into an external knowledge workspace (ending "That workspace is not a repository dependency or a new register.").
- `docs/model-family-qualification.md`: the two `<home>/Areas/Kogen/studio-work/...` locations become a plain statement that those receipt and launch records are retained privately by the owner and are not part of this repository; the hashes and facts around them stay.
- `docs/evidence/bundled-zip-safety/receipts/runtime.txt`: the machine name becomes `<host>`.
- `docs/testing-rules.md` stays byte-identical (SHA-256 631f7ad0ce8283fd8147656e2d1dbc9b8b7dca7e4a32af0686f9cacbedeb817c): the Go test `TestTheTestingRulesUsersReadAreTheOnesEmbedded` requires it to equal the prompt embedded in the pinned `github.com/KogenAI/kogen-executor`.
- No SECURITY.md, CONTRIBUTING.md or BRANDING.md is added.

Unchanged: production code under `cli/`, `spec/`, `packaging/`, `test/`, `examples/`, `.github/`, `.kogen/project.yaml` and every protected file. The change set is README.md, files under `docs/`, existing records under `.kogen/intents/`, the five step files named above, and this Intent's own files.

Left in the tree for the owner, out of scope: `cli/third_party/kogen-loop/docs/provenance/extraction.md` lines 10 and 12 (home path, personal name) and `cli/third_party/kogen-loop/README.md` lines 33 and 70 (host name: the short alias of the bench host), both in the protected vendored copy written only by `packaging/sync-kogen-loop.sh`, so the fix belongs in the kogen-loop repository followed by a re-pin; the `no-home-paths` check line of `.kogen/project.yaml` (a search pattern, not a path); the historical internal notes in `docs/testing-rules.md` (changing them needs a kogen-executor change and a protected `cli/go.mod` re-pin); historical evidence records (`docs/evidence/`, `docs/k-acceptance-fixed-wait.md`, `docs/round-targeted-tests.md`, `docs/kogen-066-loop-change.md`, `docs/check-time-measurements.json`) stay as records because committed Intents and tests reference them, cleaned only of the scan kinds.

History hits for the owner, not changed (commit, file, kinds found in lines it added, oldest first; same scan kinds, all history reachable from HEAD). Besides these, every commit's author and committer metadata carries the owner's personal name and e-mail address, and the messages of commits e7a40fb and 7681f65 name the owner.
- f0d9133 .kogen/intents/reuse-ready-evidence-v2/intent.md: home path, personal name
- 5fdabfe .kogen/intents/resume-failed-builds/intent.md: personal name
- b2c9876 .kogen/intents/faster-shaping/intent.md: personal name
- 7bc4fe2 docs/evidence/compact-shaping-context.json: home path, personal name
- 7bc4fe2 test/support/compact_context/README.md: home path, personal name
- 43c423f .kogen/intents/clean-candidate-verification/intent.md: home path, personal name
- f3ff107 .kogen/intents/bundled-zip-safety/intent.md: home path, personal name
- f3ff107 docs/evidence/bundled-zip-safety/README.md: home path, personal name
- f3ff107 docs/evidence/bundled-zip-safety/receipts/acceptance.ndjson: home path, runner path, personal name
- f3ff107 docs/evidence/bundled-zip-safety/receipts/configured-checks.json: runner path
- f3ff107 docs/evidence/bundled-zip-safety/receipts/runtime.txt: host name, personal name
- c3ee2a8 .kogen/intents/fail-fast-verification/intent.md: home path, personal name
- 42c9cce .kogen/intents/clean-readiness-parity/intent.md: home path, personal name
- f3150d0 .kogen/intents/reopen-blocked-review/acceptance.feature: home path, personal name
- f3150d0 .kogen/intents/reopen-blocked-review/intent.md: home path, personal name
- 3ef1f17 .kogen/intents/reviewer-style-discipline/intent.md: personal name
- 7af8400 .kogen/intents/provider-wait-boundary/intent.md: home path, personal name
- f91c44c .kogen/intents/cache-capability-fallback/intent.md: home path, personal name
- 71f7b4f .kogen/intents/build-continuity/acceptance.feature: personal name
- 71f7b4f .kogen/intents/build-continuity/intent.md: home path, personal name
- 71f7b4f features/steps/build_continuity_steps.js: personal name
- 007087b .kogen/intents/native-image-evidence/intent.md: home path, personal name
- 007087b features/steps/native_image_evidence_steps.js: home path, personal name
- d71b358 .kogen/intents/supergrok-subscription-20261022/intent.md: personal name
- d71b358 features/steps/supergrok_subscription_steps.js: home path, personal name
- 44c2e06 .kogen/intents/shape-working-context/acceptance.feature: personal name, home path
- 44c2e06 .kogen/intents/shape-working-context/intent.md: home path, personal name
- 65640c6 .kogen/intents/shape-context-index/acceptance.feature: personal name, home path
- 65640c6 .kogen/intents/shape-context-index/intent.md: home path, personal name
- 0e43500 .kogen/intents/review-refine-working-room/acceptance.feature: personal name, home path
- 2137fa9 .kogen/intents/transient-stream-retry/intent.md: personal name
- 48bc5ef test/support/deterministic_check_gate/mix-test.txt: runner path
- 71dd6da .kogen/intents/bounded-tool-results/acceptance.feature: home path, personal name
- 71dd6da .kogen/intents/bounded-tool-results/intent.md: home path, personal name
- db0c02e .kogen/intents/staged-intent-builds/acceptance.feature: home path, personal name
- db0c02e .kogen/intents/staged-intent-builds/intent.md: home path, personal name
- c30caf3 .kogen/intents/shape-working-summary/acceptance.feature: home path, personal name
- 97d8597 .kogen/intents/approval-card-recovery/intent.md: home path, personal name
- 828dfa5 .kogen/intents/all-provider-cache-reuse/intent.md: personal name, home path, runner path
- 828dfa5 features/steps/all_provider_cache_steps.js: personal name
- d0bc4af .kogen/intents/go-core-migration/intent.md: personal name, home path
- d0bc4af cli/project/testdata/facts-golden.json: home path, runner path, personal name
- d0bc4af cli/project/testdata/parity.json: home path, personal name
- d0bc4af docs/evidence/go-core-migration/accumulated-suites.md: home path, personal name
- d0bc4af features/steps/build_continuity_steps.js: personal name
- f38e488 docs/check-time-measurements.json: home path, personal name, runner path
- a0b5e84 .kogen/intents/model-family-profiles/intent.md: home path, personal name
- a0b5e84 docs/model-family-qualification.md: home path, personal name
- 3f03220 .kogen/intents/chatgpt-cache-affinity/intent.md: home path, personal name
- 44f0bc2 .kogen/intents/extract-loop-executors/intent.md: home path, personal name
- 44f0bc2 cli/third_party/kogen-loop/docs/provenance/extraction.md: home path, personal name
- 44f0bc2 docs/evidence/extract-loop-executors/README.md: home path, personal name
- 44f0bc2 docs/evidence/extract-loop-executors/history/affected-acceptance.log: home path, personal name
- 44f0bc2 docs/evidence/extract-loop-executors/history/integration-reference-v2.json: home path, personal name
- 44f0bc2 docs/evidence/extract-loop-executors/history/native-loop-delivery.json: home path, personal name
- 44f0bc2 docs/evidence/extract-loop-executors/history/review-diff-debug.log: home path, personal name
- 2b8bf96 .kogen/intents/k5-loop-repin/intent.md: home path, personal name
- 2b8bf96 features/steps/k5_loop_repin_steps.js: home path, personal name
- c75e867 .kogen/intents/k5b-loop-repin-ksafe/intent.md: home path
- 2c21e0b .kogen/intents/k18-reset-thinking-binding/intent.md: home path, host name
- 31d432f .kogen/intents/k-perf-2-shape-tests/intent.md: host name
- c59b187 .kogen/intents/k-onboard/intent.md: personal name
- 490626d .kogen/intents/k-pin-knobs/intent.md: home path, host name
- 490626d cli/loop_knobs_test.go: home path, host name
- 490626d cli/third_party/kogen-loop/README.md: host name
- 490626d docs/evidence/k-pin-knobs/README.md: home path, host name
- 2418bfb .kogen/project.yaml: home path, runner path
- 5ec1959 .kogen/project.yaml: home path, runner path
- d99584e .kogen/intents/k-research-remove/intent.md: personal name
- 56c115c cli/project/testdata/facts-golden.json: home path, runner path, personal name
- cace62d .kogen/intents/k-drop-shelltimeout/intent.md: personal name
- 9148fa7 cli/third_party/kogen-loop/README.md: host name
- 797d03a .kogen/intents/k-approve-deadline/intent.md: home path, runner path, personal name
- 33bbe2e .kogen/intents/k-review-verdict-strand/intent.md: host name
- c8dae5a .kogen/intents/k-hook-prevalidation/intent.md: runner path, host name
- 8744e67 .kogen/intents/k-pin-test-mac-path/intent.md: runner path, host name
- 8e75f8c .kogen/intents/k-go-test-critical-path/intent.md: runner path
- 09f59c0 .kogen/intents/k-shape-long-replies/intent.md: home path, runner path, personal name
- d42f6cc .kogen/intents/k-hung-check/intent.md: host name, home path, runner path, personal name
- 3e759e8 .kogen/intents/k-review-resume/intent.md: runner path
- e104bed .kogen/intents/k-baseline-per-base/intent.md: runner path
- 9ecaba7 .kogen/intents/k-review-invalid-resume/intent.md: runner path
- 5e59495 .kogen/intents/k-checktime-shard/intent.md: host name
- 8afac45 cli/third_party/kogen-loop/README.md: host name
- 63aac76 cli/third_party/kogen-loop/README.md: host name
- e7d7d73 .kogen/intents/k-go-test-parallel/intent.md: home path, runner path, host name
- 08ae506 .kogen/intents/k-probe-mix-home/intent.md: home path, host name, runner path
- 57fee35 .kogen/intents/k-review-catalog-repin/intent.md: runner path
- 3896094 cli/third_party/kogen-loop/README.md: host name
- af51c70 .kogen/intents/k-shape-contract-consistent/intent.md: runner path
- 733363b .kogen/intents/k-review-source-bound/intent.md: runner path
- 816b0b0 .kogen/intents/k-shape-data-stores/intent.md: host name

## Decisions
- The README introduction, before its first `## ` heading, says that this repository is `kogen`, the command-line program that is Kogen's small core, and links https://kogen.dev (source: request)
- The README setup and test steps start from `git clone https://github.com/KogenAI/kogen`, use the toolchain from `.tool-versions` and need no private-module, mirror or token setup (source: request)
- `contact@kogen.dev` is stated exactly once in the README, in its Contact section (source: request)
- Kogen-wide links point to https://kogen.dev or https://github.com/KogenAI/kogen (source: request)
- There is no SECURITY.md, CONTRIBUTING.md or BRANDING.md, no contribution refusal or maintenance promise, and nothing says that issues or pull requests are disabled (source: request)
- Records keep what they say; private values become the placeholders `<home>`, `<work>`, `/var/folders/.../`, `<host>`, "the owner" and `<owner-email>`, and fixtures use the synthetic `Owner` and `cache-fixture@example.invalid` (source: request)
- Git history is not rewritten; its hits are listed in this Intent for the owner (source: request)

## Source comparison
- addressed: README for a public reader (component, role in Kogen, setup and test from a plain public clone with the Go toolchain, nothing private or unavailable) -> README rules above; scenario "The README introduces the component to a public reader".
- addressed: every link resolves publicly; Kogen-wide links to https://kogen.dev or https://github.com/KogenAI/kogen -> Markdown link check (relative targets exist inside the repository, absolute targets are https, Kogen hosts limited to those two) in scenario "Links resolve publicly and nothing points into the private workspace"; the private knowledge-workspace and receipt references in docs/configuration.md and docs/model-family-qualification.md are removed. All KogenAI repositories named in the tree answered publicly (HTTP 200) when shaped.
- addressed: contact@kogen.dev stated once in the README -> exactly-once check.
- addressed: no SECURITY.md, CONTRIBUTING.md, BRANDING.md, contribution refusal or maintenance promise; issues and pull requests unmentioned -> file-absence check and README none-of check. None of these files exists now.
- addressed: no runner or home paths, host names, private URLs in the current tree; test fixtures use synthetic values -> tree scan scenario; fixture e-mail becomes cache-fixture@example.invalid.
- addressed: Intent records under .kogen/intents/ carry no runner or home paths, host names or personal names, replaced with neutral placeholders keeping what each record says -> placeholder rules; two placeholder scenarios with exact examples from twelve records.
- addressed: behaviour unchanged, every existing check passes, no assertion weakened -> configured checks unchanged (existing); docs/testing-rules.md byte-identity and the README sentence asserted by cli/compatible_login_test.go are kept and checked.
- addressed: Git history never rewritten; history hits listed (commit, file, what was found) -> list in this Intent, kinds only so the list does not republish the values.
- addressed: private-module setup -> none exists at this HEAD (no GOPRIVATE, insteadOf or mirror lines anywhere); none is added.
- conflicting, settled: Scope says only README and documentation files change, while Need asks that test fixtures use synthetic values and the h16 scope covers committed Intent records. Settled: step files listed in committed records' Acceptance are part of those records and change only at their hits; owner-only retained-evidence locations use os.homedir() instead of a synthetic path because they are evidence locations, not fixtures, and this keeps behaviour unchanged.
- omitted (out of scope): .kogen/project.yaml and every protected file, including the vendored cli/third_party/kogen-loop/docs/provenance/extraction.md hits (listed for the owner). The build-host override lines named in the request are not present in this HEAD's .kogen/project.yaml; its only match is the no-home-paths search pattern, which is not counted.
- omitted (behaviour): docs/testing-rules.md internal notes stay because the file must equal the prompt embedded in the pinned kogen-executor module.
- omitted (records): historical evidence documents stay as records referenced by Intents and tests; only the scan kinds are replaced. Non-Markdown URLs are third-party public endpoints, examples or localhost test addresses and are left as they are.
- superseded: the README claim that no release is published (development prereleases exist at https://github.com/KogenAI/kogen/releases).

## Tests
- No runner or home path, host name or personal name remains in any tracked or new text file outside the out-of-scope files: scenario "No runner or home path, host name or personal name remains in the tree" (scenario)
- Intent records keep what they say with neutral placeholders: scenarios "Intent records keep what they say with path placeholders" and "Intent records keep what they say with host and owner placeholders" (scenario)
- Step files that share a replaced literal stay consistent with their records and keep reading the same locations: scenario "Step files that share a replaced literal stay consistent with their records" (scenario)
- The README introduces the component, links https://kogen.dev, starts setup from a public clone, states contact@kogen.dev once and drops internal notes: scenario "The README introduces the component to a public reader" (scenario)
- Every Markdown link resolves publicly, Kogen-wide links use the two public addresses, no policy files exist and maintained documentation names no private workspace location: scenario "Links resolve publicly and nothing points into the private workspace" (scenario)
- Program behaviour is unchanged and no assertion is weakened: the configured checks format, compile, test, go-test (including TestTheTestingRulesUsersReadAreTheOnesEmbedded and the README assertion in cli/compatible_login_test.go), no-home-paths, spec and cucumber pass unchanged (existing)
- Git history is never rewritten: the Build adds one commit on the current HEAD (existing)

## Feasibility
- none

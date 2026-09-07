# Bootstrap acceptance evidence

Date: 7 September 2026.
Intent: `01a071fd-7bf0-7eb9-87b4-044f5b3cefac` (`bootstrap-core`).
Reviewed source Candidate: `8093df6d54c7d51326ec7c6d815334cd6a7af908`.

## Construction and authority

This is a coordinator-led bootstrap, continuing earlier implementation work. It is not a self-hosted Kogen Build or a clean-room rewrite. The retained approval mandate and identity are unchanged. Dedicated Astra high shaping repaired and finally checked the core Intent. Implementation repairs used parallel workers, with independent Sol high review; the shipped runtime remains Sol high for shaping, Terra high for development and resumed rework, and Sol high for review.

The core exposes Shape and Build only. Fixture approvals below are explicitly scripted test data, not approval of a real feature.

## Original bootstrap verification — before publication edits

- `make check`: **86 passed, 3 live tests excluded**, 65.7 seconds. Formatting, warnings-as-errors compilation, strict Credo, Boundary negative controls, and all offline tests passed.
- `make live`: **3 passed, 86 offline tests excluded**, 495.3 seconds, using the confirmed Sol/Terra/Sol high lineup. This covers direct transport/resume, connected public Shape-to-Commit, and separate real Build reviewer rework.
- The source Candidate remained `8093df6d54c7d51326ec7c6d815334cd6a7af908` after both gates; an independent reviewer also verified all 53 source-file hashes against the frozen manifest.
- Final independent Sol high acceptance of this source, contract, and evidence: **ACCEPTED**, 7 September 2026.

### Connected real public Shape-to-Commit

The public shaping command minted Intent `01a07a19-7b30-7614-915f-eb489d688367`. Its Draft existed before the explicit fixture approval, and public Build used that same package. Developer `01a07a1a-7e3a-7953-a590-e50fa7698bee` received a real failing Stop Check for Candidate `fc6f8e2e344593e0e87bdb688005f24a02456589`, corrected it within the same conversation, and obtained a passing Stop Check for Candidate `b3194460bf9a325da539bdb1acc3a2cc3e63a80a`. It consumed zero outer resumptions. Fresh Reviewer `01a07a1b-0fdd-7c12-809a-1ecfff064aa9` accepted. Fixture commit `2ff62b008523aa1a0a74121f0da66c5be122d43c` carries that shaped Intent's exact identity trailers and Complete package.

### Real reviewer-directed rework

The separate Build-only fixture does not substitute for public Shape coverage. Real Reviewer `01a07a16-3d8c-7941-a1ae-5ab47cbbd59d` returned concrete rework findings. Build resumed original Developer `01a07a15-324d-79f1-8865-588b41ac235d`, obtained a new passing Check for revised Candidate `24fd6b6b8497f8f10c526c84a708cccd90345f1c`, and obtained acceptance from fresh Reviewer `01a07a17-c78f-72c0-a68a-89b804f09dfd`. The test verified the resulting Complete package and commit trailers, with exactly one outer resumption.

## Scenario coverage

| Scenario | Observed evidence |
| --- | --- |
| `shape-and-explicit-approval` | Public fake Shape preserves minted identity, branch, HEAD, and role provenance; the connected fake and real lifecycles preserve the exact approved package. |
| `build-preconditions` | Missing/invalid inputs and targets, dirty/detached state, existing Complete, held lock, and lock cleanup pass the offline precondition cases without provider launch. |
| `stop-owned-check` | Production hook tests exercise configured execution, role isolation, broken-candidate failure, valid control-character JSON, and session-bound records; real connected lifecycle records ordered failure and pass. |
| `exact-verification-and-rework` | Missing/stale/failed record tests, cleanup-failure refusal, bounded exact-thread resumption and exhaustion tests pass; real rework records a renewed Check and fresh Review. |
| `independent-review` | Fresh role execution, malformed/provider-failed/empty-rework refusal, Developer-session reuse rejection, and Reviewer-mutation tests pass; live Reviewer IDs are distinct. |
| `approved-input-integrity` | Developer, Reviewer and verification-target mutation tests pass; symlinked approval inputs are rejected before launch. |
| `candidate-integrity` | Tracked ignored and force-staged ignored source participate in the Candidate; outside-path staging changes are rejected; private index/commit artifacts avoid process collisions. |
| `paths-with-spaces` | Actual fake-harness executable and prompt execution run through spaced paths, and production hook configuration executes in a spaced checkout. |
| `fake-full-lifecycle` | Public fake Shape through exact approval, failed/pass Check, Reviewer rework, exact resume and fresh acceptance commits the final artifact and Complete package with original trailers. |
| `live-full-lifecycle` | Final three-test real gate passes; connected public Shape-to-Commit and separate real Reviewer rework have retained provider streams and receipts. |
| `publication-and-failure` | Commit-failure rollback, original evidence preservation, duplicate/late Complete refusal and commit-provenance tests pass. |
| `core-release-boundary` | Source exposes only Shape and Build as Kogen public tasks and contains no Claude runtime or version command. The bootstrap publication procedure verifies the required parent and exact message below. |

## Bootstrap publication and limits

The bootstrap commit must be the one commit on this branch directly after `3f5af338533580658e1069e21091d63d93e96f79`, with subject `Bootstrap the core` and trailers `Kogen-Intent-ID: 01a071fd-7bf0-7eb9-87b4-044f5b3cefac` and `Kogen-Intent: bootstrap-core`. Only this Complete package's bookkeeping may differ from the reviewed source Candidate. Exact resulting commit metadata and fresh-checkout verification are post-commit checks recorded in the private release report; this pre-commit record does not claim those checks have already happened.

Raw terminal/provider streams, manifests and full gate logs remain in the private campaign archive. This package contains the concise factual account only. macOS with Codex CLI 0.153.4, Elixir 1.20 and OTP 29 is the verified environment. This proves the repository-local core and disposable fixtures; a human-approved follow-up self-hosted feature remains separate work. No remote push, public release, canonical integration, or history pruning is part of this bootstrap commit.


## Publication amendment — 7 September 2026

The bootstrap was amended at Almir’s request to clarify its public documentation
and role instructions. The human is the Shaper; the agent is the Shaping
Controller. Developer rework now resolves findings against evidence and the
Approved Intent, with fresh independent Review still required. Public copy
explains the core as the starting point for building the rest of Kogen, makes
no external-contribution or maintenance promise, and uses contact@kogen.dev
for questions, inquiries, and private vulnerability reports. Internal handoff
instructions were replaced with the construction account above.

Verification on the amended files before commit:

- `make check`: **86 passed, 3 live tests excluded**, 65.3 seconds.
- `make live`: **3 passed, 86 offline tests excluded**, 489.3 seconds. The
  connected shaping/approval/Build fixture and the separate reviewer-directed
  rework fixture passed with the revised prompts.
- Independent read-only Luna review found no blocking defects in the requested
  changes. Existing runtime algorithms and internal role identifiers were unchanged.
- All 53 source files outside the Complete package matched the tested manifest
  after both gates. SHA-256 of that manifest: `36eb173b6757e159d68200b04117d567c6949c78dadb1324216a635714fbd777`.

The original results above remain attributed to the original source Candidate.
They are not substituted for this amendment’s checks. Raw logs and the manifest
remain private. The amendment preserves the bootstrap’s parent, subject, and
Intent trailers; exact resulting commit metadata and fresh-checkout verification
are recorded after the amend in the release receipt. These fixtures do not
constitute a human-approved follow-up feature or a demonstration of the fuller
product, and no remote publication is performed by this amendment.


## Unversioned work-in-progress correction — 7 September 2026

Public copy now describes ongoing development without a numbered release or
redundant policy files. Questions and inquiries use the README’s contact address.
Mix requires version metadata to compile; its fixed unversioned placeholder is
build-tool metadata, not a product release.

The offline suite exposed nested tests inheriting the parent fixture’s raw-log
directory. Test startup now clears that inherited variable; fixtures that need
logs explicitly select their own directory. Assertions and production behavior
are unchanged. Independent Luna review accepted the correction.

Final `make check`: **86 passed, 3 live tests excluded**, 65.2 seconds. An
isolated lifecycle reproduction also passed. Earlier failed runs and the
preserved fixture establish the test-log contamination; those failures were
not counted as passes. No real-provider gate was rerun for these copy, build
metadata, and test-isolation changes. Earlier live results remain attributed
to the source reviewed above; production runtime code and prompts are unchanged.

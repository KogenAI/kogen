# Bootstrap the core

## Feature and authority

Provide the repository-local Kogen core through two public commands: `mix kogen.shape` and `mix kogen.build <slug>`. A human shapes one feature with an interactive Codex Shaping Controller and explicitly approves its Intent. Build then implements that exact package, checks the candidate, obtains independent Codex review, handles bounded rework, and makes the resulting Commit with a Complete Intent.

Almir authorized this bootstrap directly. It was constructed with coordinating
Codex agents, implementation workers, and independent review, continuing earlier
implementation work. It was not built by Kogen itself and is not a clean-room
rewrite. The retained Intent identity is `01a071fd-7bf0-7eb9-87b4-044f5b3cefac`
with slug `bootstrap-core`. Scripted approvals in lifecycle fixtures are test
data, not human approval of a real feature.

## Shaping and approval

Read the tracked `.kogen/config.yaml`, including the configured model and effort for shaping, development and review and the outer resumption limit. Missing required configuration fails clearly instead of inventing defaults. Codex is the runtime harness for all three roles.

Shape mints and prints one UUIDv7, captures the current branch and HEAD, and launches the interactive Codex Shaping Controller attached to the caller's terminal. The Shaping Controller works with the human Shaper on one coherent feature, its appetite, boundaries, scenarios and consequential product, UX and technical decisions. Unresolved decisions remain questions; agents do not invent additional public interfaces.

The Shaping Controller writes `.kogen/intents/drafts/<slug>/` with `intent.yaml` and `scenarios.yaml`, and references, questions or evidence where useful. Preserve the minted identity, title, slug, shaped-against revision, shaping provenance and permitted guarded paths. Each scenario states its starting conditions, action, expected result, plausible wrong result and actual Make targets for verification. The package must capture the feature precisely enough to build autonomously. Only explicit human approval in that shaping conversation permits moving the whole Draft to `.kogen/intents/approved/<slug>/`. There is no separate approval command and no core Intent-validator subsystem; the Shaping Controller prepares a coherent package and the human Shaper alone approves it. Build performs the basic reads and precondition checks needed to execute safely.

## Autonomous Build

Build reads the selected Approved package. Before calling a provider, require a clean worktree, an attached branch, no existing Complete package for the slug, an exclusive local Build lock, a declared `check` target and safe, declared scenario verification targets. Release the lock on ordinary completion or failure. Preserve the Approved package's entries and bytes throughout execution; mutation by any role or verification step must stop publication.

Launch one Codex Developer conversation with the approved identity, scenarios and guarded paths. The Developer implements the shaped feature, respects the Approved package as read-only and uses focused development checks as needed. The tracked Codex Developer Stop hook alone runs the Build's `make check` gate. It must operate even when the candidate cannot compile, record the actual candidate tree and Developer session, and block a failing stop with actionable output so Codex continues the same turn. Shaping Controller and Reviewer stops must not run this gate. Clear stale verification records before each Developer launch or resume.

After the Developer settles, accept Check only when a passing record matches both the current candidate and that Developer session. Run every additional declared scenario target, preserving its actual result. A missing, stale or failed Check or a failed extra target supplies rework feedback. Do not call `make check` again from the coordinator or Reviewer as a substitute for the Stop-hook gate.

Review starts a fresh Codex conversation independent of the Developer thread. It reads the Approved package and exact candidate, checks every scenario and returns only the structured verdict `accept` or `rework` with concrete findings. Malformed/provider-failed review stops the Build. Review must leave both the candidate and Approved package unchanged; detect mutation before either rework or publication. Findings or unsettled verification resume the exact original Developer thread within the configured outer resumption budget, with fresh Check and fresh independent Review afterward. In-turn Stop-hook corrections consume no outer resumption. Budget exhaustion stops without a completion commit.

## Candidate and publication

Candidate identity is an exact Git tree containing all source that would be committed, including tracked or already staged files that match ignore rules. Ignored, untracked runtime artifacts do not become source. Check, Review and final staging must agree on that source tree. Checkout paths containing spaces must work through the harness and Stop hook.

After accepting Review, move the same Approved package into `.kogen/intents/complete/<slug>/`, preserving its evidence, and add factual completion evidence: candidate, Developer and Reviewer session identities, settled Check result, additional target results, verdict and resumption count. Stage and verify that only this lifecycle bookkeeping differs from the accepted source candidate. Commit the implementation and Complete package together with the Intent title and identity trailers. On a failed commit attempt, restore Approved and remove the tentative Complete package. User-installed Git hooks remain the user's responsibility; introduce no new hook management policy.

For this bootstrap, record exactly one commit directly after `3f5af338533580658e1069e21091d63d93e96f79`, with subject `Bootstrap the core` and trailers:

```
Kogen-Intent-ID: 01a071fd-7bf0-7eb9-87b4-044f5b3cefac
Kogen-Intent: bootstrap-core
```

Bootstrap evidence must state the actual coordinating process and actual observed verification, including any unmet scenario. Neither fixture success nor an unexecuted test constitutes a live pass or approval.

## Verification and boundaries

`make check` is offline: formatting, compilation with enforced architectural boundaries, static checks and deterministic fake-Codex tests. It must never call a real provider. Fake coverage must exercise the public Shape entry point, explicit fixture approval of its exact Draft, public Build, Stop Check, independent Review, rework and resulting Commit. Test precondition failures, stale/missing/failed checks, bounded same-thread resumptions, candidate and approval mutation, and failed publication.

`make live` is a separate explicit provider-backed gate. Real Codex coverage must carry the exact package from the public shaping command through explicit scripted fixture approval, public Build, actual failed-then-passed Stop Check in one Developer session, fresh independent Review and the resulting Commit. Cover reviewer-directed rework with real provider evidence as part of the live lifecycle coverage. Preserve actual transcripts, raw streams and receipts so transitions can be audited. Full lifecycle claims require all transitions, not an independently prewritten Approved package.

Use the confirmed shipped models and high effort in final live proof: Sol for Shape, Terra for development and resumed rework, and Sol for every independent Review. Historical Astra transport probes do not establish these roles' acceptance. Hook evidence must show Codex loaded the tracked `.codex/hooks.json` and invoked its Developer Stop command, with the actual Developer thread identity; manually invoking that command proves only the script. Failed-then-passed Check records must be ordered and candidate-specific, and the settled pass must match the candidate presented to Review.

Real reviewer-directed rework means an actual fresh Reviewer returns actionable `rework` findings, Build resumes the original Developer thread with those findings, the hook records a new passing Check for the revised candidate, and another fresh Reviewer returns `accept` before Commit. In-turn Check correction alone does not satisfy this transition. It may occur in the connected Shape-to-Commit fixture or in a separate real Build fixture; label a separate fixture as Build-only evidence and retain the connected public Shape-to-Commit proof. Fixture instructions may arrange an intentional omission to exercise Review, but the real Reviewer must observe it and emit the verdict; fabricated provider output is fake coverage.

Before the bootstrap is marked Complete, the frozen source must pass the full offline and live gates and receive fresh independent review of this contract, that source and its actual evidence. Completion evidence maps all twelve scenarios to observed results, distinguishes fixture commits from the bootstrap commit, and records any remaining limitation. Final parent, subject and trailer checks and fresh-checkout verification apply to the exact resulting bootstrap commit; pre-commit checks alone cannot prove that metadata. Keep raw provider evidence private and include only a concise factual evidence account in the released package.

Exclude Claude runtime support, `mix kogen.version`, an installer, daemon, hosted service, additional harnesses, new public UX, a separate approval interface and a runtime Intent-validator subsystem. This Intent delivers the core; unrelated features require their own shaping.

## Model selection

The shipped Codex defaults are Sol high for shaping, Terra high for implementation and resumed rework, and Sol high for independent review. Astra high is used only to shape this initial core; the normal Shaping Controller and Reviewer use Sol high.

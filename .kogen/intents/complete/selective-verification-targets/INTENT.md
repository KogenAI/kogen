# Split verification into selective targets

## Outcome

Shaping can assign the smallest sufficient declared verification targets to an Intent and explain why each provider-backed target is necessary. `make check` remains the complete offline gate. Ordinary changes no longer inherit every `:live` case merely because they need one affected workflow verified.

The target boundary is:

| Target | Owner and purpose | Provider-backed? |
| --- | --- | --- |
| `check` | Existing warm, complete offline gate: format, forced warnings-as-errors compilation, strict Credo, fake lifecycle, deterministic rehearsals and all non-live tests | No; provider dispatch remains denied |
| `live` | Integrated acceptance for the configured default role combination: connected public Shape-to-Build lifecycle, Stop-owned verification, independent Review and Reviewer-rework/semantic preservation | Yes |
| `live-shaping-quality` | Maintained seven-case public Shaping evaluation and its required evidence manifest; `check` continues to own its deterministic offline rehearsal | Yes |
| `live-native` | Managed Codex runtime/login compatibility, authenticated compatibility runner, and real native-helper routing/receipt coverage | Partly; treat the target as provider-backed because some owned cases require login and native dispatch |
| `cold-offline` | Complete offline gate from an empty private build cache, with copied dependency sources and provider-denial control | No; expensive wall-clock work is not paid evidence |

`live` is not an alias for all specialized targets and does not become a future all-harness matrix. It proves one integrated route using the currently configured default role combination. The recipes must select owner files/modules explicitly enough that adding another `:live` case does not silently expand unrelated targets.

## Selection guide for future Shaping

Every Build always starts with `check`. Add only targets whose workflow, boundary, or preservation behavior can materially change:

- Add `live` for public Shape/approval/Build orchestration, Developer handoff or resume, Stop/receipt settlement, Review/rework/publication flow, configured default root-role routing, or shared lifecycle fixture setup and cleanup. Include it for preservation when a change could leave the happy path passing while breaking failure recovery, same-Developer rework, fresh Review, or Candidate binding.
- Add `live-shaping-quality` for Shaping prompts/instructions, conversation or continuation behavior, Draft quality/readiness requirements, the maintained evaluation cases, source/prerequisite delivery, evaluator collection, or the shaping evidence manifest. A generic lifecycle pass cannot substitute for the semantic case set.
- Add `live-native` for managed runtime installation/discovery/login/scope, Codex native transport/session behavior, launch environments, native compatibility, helper routing/profiles, or native receipt collection. Mocks and synthetic credentials establish offline mechanics only; select this target when the claim depends on the installed authenticated native boundary.
- Add `cold-offline` for the offline recipe, dependency/build-cache behavior, compiler/toolchain setup, private dependency copying, cache isolation, process containment, or cleanup that may differ from a warm checkout. Do not add a paid target merely to prove cold behavior.
- Use only `check` when the affected behavior and its preservation/failure controls are fully exercised behind the denied-provider offline route. Editing a live test file is not by itself sufficient reason to run its target, and leaving a live file untouched is not sufficient reason to omit an affected workflow.
- If more than one boundary is affected, select each relevant target in scenario order. Do not select both a broad alias and its component; these targets have no aggregate alias. Historical receipts and stale successes never replace fresh Candidate-bound execution.

The Intent must state the causal reason for every selected non-`check` target in scenario evidence or supporting prose. “It is live” or “the file changed” is insufficient.

## Bootstrap constraint

Build loads the Approved contract and validates every non-`check` `verified_by` name against the Makefile before launching a Developer. The four new targets do not exist at this shaped baseline. This Intent therefore uses only the already-declared `[check, live]` targets for its own scenarios. Its Build adds and tests the new declarations; only later Intents may name them. The implementation must not weaken, defer, or bypass pre-launch target validation.

The existing broad `live` is required once for this bootstrap Candidate because verification ownership itself and every current live owner are being repartitioned. This is not a precedent that ordinary later changes require all specialized targets: after this Intent, `live` has the narrower contract above.

## Acceptance and preservation

Implementation must inventory all current cases selected by `mix test --only live` and assign each exactly once to `live`, `live-shaping-quality`, `live-native`, or `cold-offline`. No case or assertion is deleted, skipped, weakened, re-labelled flaky, or left reachable only through an undocumented command. Offline tests must deterministically inspect or rehearse the target recipes and prove:

- all target names are declared and accepted by existing target validation;
- `check` excludes every provider-backed case and retains provider denial;
- `cold-offline` selects only its cold owner and retains the no-provider-dispatch assertion;
- `live` does not select shaping-quality, native-specialized, or cold-offline owners;
- every pre-split live owner is selected by its documented target;
- shaping evaluation evidence forwarding is exercised offline before its paid owner can be relied on;
- Stop still runs `check` first and then distinct scenario targets in first-occurrence order, with the existing retry, Candidate/session/attempt binding and required-artifact rules.

Documentation in `README.md` and `scripts/check/README.md` must use the same target names, prerequisites, paid/offline classification, selection rules, and bootstrap limitation. It must identify `make live` as the configured-default integrated route rather than a complete suite.

## Non-goals

- Claude or any other harness adapter, all-harness matrix, or speculative harness-target framework
- automatic dependency- or changed-file-based test selection
- stopped-Build continuation or recovery of `recover-plugin-prevention`
- new logging or evidence infrastructure
- write-protection guards
- retry/outer-allowance increases
- reusing stale gate passes
- cancellation policy for already-started independent paid cases

The stashed `recover-plugin-prevention` Candidate and its Approved package remain untouched. Its latest failure is problem evidence only.

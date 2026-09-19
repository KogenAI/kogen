# Install rehearsed verification plans

## Outcome

Every future Build receives one controller-owned verification plan that catches deterministic implementation, selection, fixture, orchestration, and consumer defects before authoritative paid verification. The Developer's observations improve readiness but never become gate receipts, admit Review, alter retry accounting, or replace fresh loop-owned verification.

The plan is assembled and validated before provider launch from source-declared target metadata, the Approved scenarios' machine-readable focused proof selectors, guarded paths, and the Candidate's changed paths. It travels in the existing versioned verification context consumed by Stop. The existing `.codex/hooks/**` files remain byte-identical; this installing Build continues to use the old Stop-owned protocol, while offline future-Build fixtures exercise the newly installed plan.

## Contract

### Target catalog and execution order

Maintain one source-owned catalog for every declared verification target. Each entry names its stable target identity, cost class/rank, dependencies, provider-backed status, and provider-denied rehearsal identity when provider-backed. `check` is the required root and always runs first. Remaining selected targets are normalized, deduplicated, dependency-validated, and ordered by dependency, then declared cost rank, then stable target name. Scenario order no longer controls execution order.

The catalog is exhaustive against declared Make targets used for verification. Missing target, rank, dependency, cycle, unknown dependency, owner/rehearsal mismatch, or missing rehearsal metadata fails before Developer dispatch. There is no implicit “unknown targets last” behavior. Metadata is part of the controller-owned plan and is checked again by offline controls; it is not hidden in mutable Stop hooks.

There is no aggregate target or alias. Retire `live` and expose exactly these maintained boundaries: `live-shape-to-build`, `live-reviewer-rework`, `live-general`, `live-shaping-quality`, `live-native`, and `cold-offline`. Split the two modules currently co-located in `live_shape_to_build_test.exs` into separately owned files so recipes select stable owner files rather than line numbers. `live-general` owns the independent semantic Reviewer challenge currently in `live_test.exs`. Every maintained source consumer—Make recipes, target policy, prompt, scenario/fixture seed, selector, contract test, documentation, and non-historical support code—must use the exact narrow target or target set it needs. Completed Intent packages and retained historical receipts remain unchanged historical evidence, not maintained execution inputs.

No Make target expands to the complete set. If a controller operation genuinely needs all boundaries, it derives and records the explicit ordered set from the catalog. Offline controls fail if `live`, `live-all`, another aggregate alias, a tag-only broad recipe, or a maintained consumer of the retired name exists.

The unchanged installing hook requires `live` in `KOGEN_VERIFICATION_TARGETS`. Preserve it only as an **installing-protocol bootstrap denial token**: it exists solely because this Build must self-host under the immutable current hook. It is not a Make target, catalog entry, prompt choice, scenario target, executable behavior, compatibility path, or alias. The policy environment contains that token plus `check` and every catalog target, not merely selected targets, so all paid Make targets remain mechanically denied. Inventory controls permit `live` only in the unchanged installing hook and this bootstrap-token producer/test, and exercise the real hook with focused-command allow and all-gate deny cases.

The next verification-authority cutover removes this bootstrap token together with the old Stop-owned protocol. Do not create generic compatibility code, fallback behavior, dual paths, deprecation machinery, or permanent legacy support around it.

### Scenario proof selectors and Shaping guidance

Extend the scenario contract additively, without replacing its existing Given/When/Then fields, with a required `proof` map:

- `offline`: a nonempty list of exact maintained selectors (test file/directory, stable named test, or maintained rehearsal; never a line selector);
- `paid_target`: one narrow additional Make target (`cold-offline` or provider-backed) or `none`;
- `paid_reason`: why offline proof cannot establish this scenario, or an explicit statement that offline proof is sufficient.
- `affected_paths`: a nonempty Shaper-authored list of implementation, assertion, and fixture paths the scenario may require; Build checks guarded-path coverage but never grants paths automatically.

Offline selectors must be normalized repository-relative paths or cataloged rehearsal identities: absolute paths, `..`, line selectors, repository/test roots, whole-suite globs, and absent unguarded paths fail admission. Existing selectors must resolve inside the admitted project root; a new selector may match `affected_paths` but must exist by handoff. `paid_reason` has a validated wire grammar: `offline-sufficient: <consumer/control>` when the target is `none`, or `provider-required: <exact-target>; observation: <provider-only observable>; offline-limit: <why its rehearsal cannot establish that observable>`. Build validates grammar, exact target agreement, nonblank distinct clauses, and catalog classification; Shaping and Review judge semantic truth rather than a keyword heuristic. `verified_by` must equal `[check]` plus the non-`none` proof target. The contract validates `affected_paths` against guards without inferring them.

`priv/kogen/prompts/shaping.md` is the authoritative producer contract: its required-file schema explicitly tells future Shaping Controllers to write and validate the `proof` map for every scenario. `Mix.Tasks.Kogen.Shape` continues to render that prompt for fresh and continued sessions. Prompt-rendering, scenario-contract, shape-task, and maintained Shaping-evaluation fixtures exercise the produced schema. Negative controls cover omitted proof, broad offline selectors, automatic selection of every paid target, paid selection without causal justification, omitted affected assertion/fixture paths, aggregate aliases, and claims that offline evidence proves provider semantics. These are deterministic prompt/schema/fixture claims, so this Intent does not select `live-shaping-quality`; no claim depends on a real model following the prompt.

README selection guidance mirrors that producer contract: each future scenario names focused offline proof, at most one causally affected narrow paid boundary, the unique evidence that requires provider access, and all affected implementation/assertion/fixture paths. Multiple scenarios may collectively select multiple boundaries. A scenario needing no paid evidence says so explicitly.

### Provider-denied rehearsal parity

Every provider-backed target declares exactly one executable provider-denied rehearsal in the catalog. Its record contains an exact repository-relative command/selector, named production preparation/selection/schema/consumer/audit/settlement entry points, paired correct and plausible-wrong fixtures, and runtime trace identities proving those shared entry points executed. `make check` invokes every cataloged rehearsal; readiness invokes only rehearsals for selected targets. Only actual provider/native transport is replaced by controlled fake output. `rehearsal-design.md` defines the required target-by-target route and disconfirming controls.

`check` derives owner/rehearsal coverage from the source catalog and production entry points rather than a copied owner list. It fails on missing or orphaned rehearsals, identity drift, empty selection, bypassed shared preparation/audit entry points, schema/consumer drift, answer leakage, or mechanically detectable owner-quality omissions. Paired correct and plausible-wrong controls pass through the real consumer and assert observable decisions/artifacts rather than exact prose.

Disconfirming offline fixtures cover: launch-plus-repair lifecycle capture-count drift; containment/control-root precondition failure before dispatch; wrong or empty owner selection; omitted guarded live assertion/fixture paths; and a fake transport whose plausible output passes a superficial parser but fails the real downstream semantic consumer. Semantic quality remains a Shaping and independent-Review judgment, not a keyword-lint claim.

### Bounded Developer readiness and honest enforcement

The rendered Developer prompt receives exact controller-issued commands, not generic advice. After relevant edits and again immediately before handoff, the Developer runs repository-wide `mix format`. After either formatting run, Build's changed-path enforcement must reject formatter changes outside guarded paths; formatting does not expand authority.

Between those format runs, the rendered prompt gives an exact controller-prescribed readiness plan:

- Credo on changed supported source files only;
- exact test file, directory, stable named test, or maintained scenario selectors from Approved proof data;
- the exact provider-denied rehearsals corresponding to selected paid targets.

This Intent does not claim mechanically safe enforcement of those scoped commands. Current source proves no immutable controller-owned command-policy generation: the registered PreToolUse script is resolved from the shared Candidate checkout, and adding another Candidate-resident classifier would let the Candidate influence the policy judging its own commands. Mechanical scoped-command enforcement is deferred until controller-generation binding or controller-owned verification supplies an admitted immutable policy path.

The exact installed design is therefore:

- implementation path: `lib/kogen/build.ex`, `lib/kogen/build/contract.ex`, and `lib/kogen/build/verification_plan.ex` validate proof selectors, construct exact readiness commands, and render them into `priv/kogen/prompts/developer.md`;
- registration path: none is added; `.codex/hooks.json` and every `.codex/hooks/**` byte remain unchanged;
- controller-owned input: validated Approved proof maps, the admission-frozen project catalog, guarded paths, attempt token, and Developer session;
- observation handling: no structured readiness-observation retention is added because current source cannot independently observe commands; ordinary Developer evidence remains self-reported and non-authoritative;
- helper inheritance: prompt and execution policy explicitly pass the same exact command set and prohibitions to helpers, and root remains responsible for their edits and observations;
- wrapper/indirection handling: the existing hook continues its bounded mechanical denial of explicit declared Make/Stop forms; the prompt forbids wrappers, shell indirection, broad test/lint, paid equivalents, and delegated evasion, but this Intent does not mislabel that broader prohibition as mechanical;
- absent/malformed input: Build fails before Developer launch and renders no fallback readiness plan;
- mutation/self-judgment: controller freezes plan inputs and revalidates Approved bytes; the existing Candidate-resident hook retains only its documented bounded lexical authority and is not described as immutable.

Tests assert exact prompt forms, a fixed derivation for changed-file Credo, helper inheritance, malformed-plan rejection, and continued mechanical denial of every catalog Make target and Stop. Python readiness/rehearsal commands use `-B`. They do not claim broad Mix commands are mechanically blocked or self-reported evidence proves execution.

Maintained prompt/documentation migration is an acceptance input: `priv/kogen/prompts/developer.md`, `README.md`, `scripts/check/README.md`, the runtime-upgrade workflow, and maintained fixtures contain no executable `make live` guidance or scenario-order execution claim. Offline inventory asserts cost/dependency-order wording and permits bare `live` only for ExUnit tags, historical evidence, and the installing-protocol bootstrap token.

Developer evidence may cite command/result locators, but the controller gives it no special readiness schema or authority. It never becomes a receipt, gate pass, Review admission, retry, or allowance input.

The authoritative `check` path completes non-mutating full-repository `mix format --check-formatted` before starting compile, lint, tests, or paid targets. Verification never repairs the Candidate.

### Controller-owned guarded-path conformance

`Kogen.Build.GuardedPaths.capture/1` runs after contract/catalog validation and before `Kogen.Codex.open/1` or provider launch. It freezes starting HEAD/tree, repository-local Git config/ignore bytes and resolved paths, one exclude policy, and a manifest only for source-relevant ignored paths; proven volatile classes are excluded (`.kogen/runtime`, `.kogen/build.lock`, `.kogen/codex`, `.codex/sessions`, `_build`, `deps`, `cover`, `.elixir_ls`, `erl_crash.dump`, Python caches, platform metadata). The snapshot remains controller memory and is never recomputed from Candidate state. `GuardedPaths.check(snapshot, guards)` runs after every Developer invocation. Candidate identity and comparison use the same frozen policy plus hardened overrides disabling executable diff/textconv/fsmonitor/status hiding. Every Git operation whose output determines changed paths or modes must additionally force `-c core.filemode=true`, independently of admitted repository configuration. Compare admitted HEAD to the private-index tree with NUL-delimited `diff-tree -r --raw --no-renames`, then relevant untracked/ignored paths. A normal passing in-turn `check` must not violate; ignored source affecting compilation/tests must be caught.

Every changed path must match a validated guard independently of existence; both rename sides must match. After settlement, verification exhaustion retains precedence, otherwise a violation uses existing outer rework before handoff/Review. No evidence or passing receipt overrides it. Controls cover guarded formatting; unguarded content/create/delete/rename/symlink/mode/helper changes; tracked/source-relevant ignored paths; Git config/ignore mutation and index-blinding flags. A dedicated negative control admits a fixture repository with `core.filemode=false`, changes only an unguarded tracked file's executable bit, and proves conformance still rejects it because comparison forces `core.filemode=true`.

Because current Stop verification still runs inside the Developer lifecycle, this post-invocation check can reject before handoff/Review but cannot prevent the installing protocol from spending a selected paid target first. Moving verification outside the Developer process tree is explicitly the next Intent; this Draft does not claim that later authority cutover.

### Structured deterministic triage

After every settled verification cycle, the controller derives a bounded signature from existing receipts: Candidate and cycle identity, failing target, cost class, first failing command/test identity, normalized bounded error head plus digest, whether failure happened before the first paid target, and whether the signature matches an earlier cycle in the same Build.

The signature is retained for every settled cycle in tracking and the final failing signature is included in the terminal stop reason. Current in-turn Stop retries receive only the unchanged hook message, and current outer rework follows passed verification so it receives no failed-cycle signature. No outer-rework delivery is required. The annotation cannot alter targets, pass/fail, receipts, retries, resumptions, Review, or publication.

## Walkthrough and challenge

A Shaper supplies selectors, affected paths, and necessary targets. Build loads a tracked project-root catalog, validates and freezes the plan. The Developer follows the prompt and formats twice. Stop runs authoritative targets; afterward Build settles receipts, checks guards, and records signatures. Exhaustion stops with the final signature; passed verification may proceed to ordinary handoff/Review rework without failed-cycle signature delivery.

A plausible wrong implementation would add narrow Make recipes and prompt text but leave scenario-order execution, falsely label Candidate-resident readiness policy as immutable enforcement, use separate fake fixtures that bypass production parsing, or treat a readiness pass as a gate receipt. The scenarios require real plan consumption, exact prompted readiness commands with honest enforcement limits, controller-owned guarded-path rejection, source-bound shared entry points, wrong/correct consumer controls, Candidate invalidation, and receipt-authority preservation so that implementation does not satisfy the words while missing the outcome.

## Non-goals

- Changing any file under `.codex/hooks/**`.
- Moving verification execution out of Stop or into the controller loop; that is the next architectural Intent.
- Changing retry counts, outer allowances, automatic retry behavior, or suppressing repeated failures.
- Provider/credential/capacity recovery or provider-failure classification.
- Worktrees, containment, dependency ownership, publication, or guarded-path enforcement beyond the exact post-Developer conformance contract defined by this Intent.
- Jev, Perch, Abide, new runtime LLM calls, or expert dispatch.
- Reusing failed Candidate code or historical receipts as current proof.
- Mechanically enforcing or specially retaining the new scoped readiness commands before controller-generation binding.
- Delivering signatures during current in-turn Stop retries.
- Making post-Developer guarded-path conformance run before current Stop-owned targets; that requires the next controller-verification Intent.
- Replacing the scenario schema beyond the additive proof-selector data required by the plan.
- Claiming literal 100% first-pass provider-backed success.

## Self-hosting boundary

The installing Build is judged by the current controller and current Stop order. It does not hot-refresh Candidate code or require the current Stop process to consume the new plan. Tests construct a future Build from installed source and prove plan construction, prompt/policy rendering, rehearsals, settlement, tracking, and failure feedback. There is no Intent-name branch, compatibility switch, or Candidate-authored settlement.

This Draft selects only `check`, so installation names no absent target. The old installing policy denies only existing names; new names are prompt-forbidden until the installed future controller supplies all-catalog policy. Each paid recipe loads alone provider-denied. A real Shaper emitting proof maps is not claimed.

### Deliberate hard contract transition

After installation, every older Approved Intent that lacks the required proof map or selects retired `live` is ineligible to Build and must return to Shaping. Build admission fails it with an actionable diagnostic; Build never moves or silently upgrades the package. This is a deliberate hard contract transition, not backward compatibility, and historical Complete packages and receipts remain historical evidence only.

The Shaper explicitly required full guarded-path enforcement and this cohesive package in the latest current-conversation direction, superseding the original brief's narrower guarded-path non-goal. Splitting narrow targets may lose prior overlap when several are selected; deterministic cost order is the accepted tradeoff.

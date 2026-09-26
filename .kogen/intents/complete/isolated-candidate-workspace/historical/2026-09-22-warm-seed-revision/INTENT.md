# Isolate Builds in Candidate workspaces

## Current revision and retained baseline

Reopened after failed Build `181SwyyMv5aW2U838Wh8xXIt`, the requested Fable-high
diagnosis and the Shaper's request to repair the Intent using cheaper readers.
This revision is Draft and unapproved; `approval.md` preserves prior approvals.
`repair-plan.md` is a mandatory
implementation instruction together with `developer-recovery.md` and
`developer-testing.md`; its controls must exist and pass before treating the
saved implementation as complete. `evidence/latest-build-reconciliation.md`
records the latest three-cycle results, Fable/Luna reconciliation and limits.

The current required source input is the complete 41-path snapshot in
`evidence/latest-implementation.json`, including repairs newer than the older
38-file checkpoint. Its inert compressed payloads travel with this package and
remain available after a clean-start stash. `developer-recovery.md` defines
safe import, hash checks, and preservation of divergent newer work. The older
checkpoint below remains history and a backup, not the preferred import source.

The historical package with Intent id `01a0bb00-009d-7f17-9fdc-3c7ac0e86a9c` was shaped and approved against `7c7c3426`. It must not be built unchanged. Commit `c1f08532` replaced material reliability contracts: offline verification now emits structured stage receipts, Make target admission has one strict inventory, provider outcomes retain initiating and cleanup causes, isolated tests require bound completion receipts, and the maintained reliability catalog binds every test declaration to current source. The old package also named three focused test files that did not exist. Building it would let workspace routing bypass, invalidate, or falsely satisfy the newly installed authority.

This Intent retains its identity and is shaped against `c1f08532`. The old approvals, probes, failed records, and stranded commit remain historical evidence only. The Shaper explicitly superseded the blanket ban on saved implementation reuse on 2026-09-22: the 38-file checkpoint `913ba174bffd864e0940c49d36d9e5d022333565` established the required reuse starting point. The current 41-file retained input includes that work and subsequent repairs; follow `developer-recovery.md`. These are unverified implementation inputs, not accepted code or reusable verification results. Do not discard that work or recreate the feature from scratch.

## Installing this revision from the saved implementation

`developer-recovery.md` is a required first-work instruction for the installing Developer. `evidence/latest-implementation.json` binds the exact baseline and current 41 changed/new file payloads; `evidence/saved-implementation.yaml` preserves the older checkpoint history. Import missing saved changes into the controller-issued project root before repair, or continue them in place if the Shaper already restored them; never apply them twice or overwrite newer work. Preserve the checkpoint and any stash. This is an explicitly authorized one-off source import into a new normal `mix kogen.build` run, not a new resume feature, adoption of an old worktree identity, reset of exhausted counters, or permission to change the running judge. The installing `c1f08532` controller still runs in its invoking checkout; the isolation behavior below is the feature being installed, not a prerequisite that the installing controller already provide it. This recovery may use the original clean-start checkout or a separately prepared clean checkout; this amendment does not require a separate worktree for the installing run. Source and Review remain measured against `c1f08532`, never against the unaccepted checkpoint as a replacement baseline.

## Outcome walkthrough

Current scope, explicitly narrowed by the Shaper on 2026-09-22: basic isolation for one active Kogen Build. Concurrent Builds, continuing a stopped Build, and integrating a Candidate with newer main are separate parked follow-up briefs, not prerequisites for this Intent. Existing same-session rework inside the running Build remains required. Successful YAML and target-plan validation is not evidence that the implementation passes; the last actual live runs failed and their corrections still need implementation and verification.

From a clean attached `main` at the admitted commit, the trusted controller creates one unique linked Candidate worktree and branch under `.kogen/runtime/build-workspaces/checkouts/<build-id>`. The control checkout remains the orchestration root and owner of locks, tracking, publication journals, and retained evidence; it is never a role's writable project root.

All current Build investigation and repair happens in its Candidate worktree. Never merge unverified changes into main and repair them afterward. This first slice refuses changed-main publication; it does not bring newer main into a Candidate. The same worktree-only boundary is recorded for future integration work, separately from this contract.

The controller materializes the frozen Approved package in the Candidate and supplies every fresh Developer, native helper, exact-session Developer resume, Stop-owned verification operation, and fresh Reviewer with an explicit `project_root` equal to the physical Candidate Git root, process cwd, generated context and environment, and absolute controller state/tracking paths. Native credentials remain selected from the admitted control account, while operation/generation state and launch discovery are Candidate-private; the controller prevalidates shared static credential-scope inputs and refuses unexpected mutation. The same Candidate survives verification retries, invalid-handoff correction, and Reviewer rework.

Candidate-private regular storage owns `deps`, `_build`, Mix/Hex/rebar homes and caches, temporary products, generated files, isolated-test receipts, offline-stage receipts, hook/target artifacts, and role evidence. Normal workspace creation has an exact warm-seed allowlist: the admitted control `deps/` and `_build/` trees are required and are cloned with the filesystem-native APFS clone-on-write primitive into distinct Candidate paths before any role launch. Ordinary Mix-shaped relative symlinks are preserved only when their lexical and resolved targets remain inside the corresponding admitted project tree and outside `.kogen/runtime`; absolute, dangling, escaping, runtime-targeting, special-file, or retargeted links fail admission. No other home or cache is seeded in this Intent. In particular credentials, account/config state, locks, sockets, receipts, logs, runtime/session state, verification/tracking state, and mutable controller state are always excluded and created or referenced through their declared private/controller owners.

The controller holds the Build identity lock, requires the seed source and destination to be on an actually clone-capable filesystem, captures a recursive path/type/mode/size/digest manifest before cloning, performs clone-or-fail with no eager-copy fallback, and confirms the source manifest is unchanged afterward. Missing required seeds, concurrent source change, stale/unsafe file types, path or symlink escape, unsupported filesystem, insufficient free space, collision, partial clone, or source mutation fails admission and removes only identity-matched partial destinations. Candidate mutation allocates private blocks and cannot change admitted seeds.

Cloning is an optimization and isolation primitive, not proof that compiled output is current. After cloning, ordinary Candidate-rooted Mix dependency validation and incremental compilation must run with Candidate-private homes and environment. Valid artifacts are reused; artifacts invalidated by Candidate source, configuration, dependency, toolchain, or environment changes are rebuilt normally. A stale `_build` control must be detected and rebuilt, while an unchanged Candidate control proves that a compulsory full clean compile is not performed. The provider-denied cold recipe remains a disconfirming recovery/readiness control, not the normal workspace-creation path.

Control owns unified verification state/history, tracking, publication state, and content-bound snapshots. Before successful Candidate cleanup, the controller copies every required Candidate artifact into tracking and rewrites retained evidence to those snapshots; Complete evidence cannot point into a deleted Candidate. First-cold verification uses the installed Gitless provenance protocol and retains source revision, Candidate/input manifest, catalog, target-plan, toolchain, provider-denial, stage, initiating-failure, and cleanup bindings.

Workspace routing preserves the installed reliability contract rather than inventing another one. The strict Make inventory and current seven-target catalog remain exhaustive. Candidate changes invalidate stale verification, rehearsal, isolated-completion, handoff, and target evidence. Provider outcomes remain classified by their initiating boundary and cleanup never replaces the provider cause. Reliability validation becomes generation-aware: unchanged rows validate against the recorded admitted reliability-generation baseline, while rows introduced or changed by the current Candidate must be source-bound to its diff. Clean-checkout, changed-row, stale-baseline, and intentionally Gitless controls prove neither path can self-satisfy. New workspace tests are reconciled into the catalog without requiring the Candidate to re-edit every implementation from the completed reliability Build.

Each scenario's `proof.offline` selectors are the Developer's causal focused-test map, not merely documentation. Follow `developer-testing.md`: the Developer runs and reruns the affected focused non-gate tests while implementing until they pass, before yielding to Stop, within the existing allowances. Selected paid boundaries also have provider-denied focused coverage that loads their real owner modules, fixtures, and setup path without dispatching a provider. Stop remains the sole owner of `check` and real declared targets; focused success never substitutes for authoritative verification.

The focused owner/setup controls must use a separate fresh OS/BEAM child for each live owner, loading only that owner and its declared dependency chain. Never preload the helper under test from another test, nor combine lifecycle and live-owner files in that child. Offline and paid owners must call the same fixture-preparation entrypoint, with a fail-closed sentinel at the actual dispatch boundary and zero dispatch attempts for prerequisite controls. Loading a similarly named audit helper, compiling the live module alone, or duplicating its setup is insufficient. Missing-helper and unsafe-seed controls must fail locally, while the realistic contained-Mix-link counterpart succeeds. For the connected route, pre-Shape fixture/seed admission uses explicitly test-only Build inputs: it cannot validate an actual shaped package before that package exists. After real Shape, the actual generated contract/plan must be admitted before Developer dispatch; that real connected route remains independently required. The source fixtures and Developer test map, not a new evidence-attestation mechanism, carry this requirement.

The installed role permits focused non-gate tests throughout development; its two-point restriction applies to the controller-issued readiness command bundle. Keep that bundle at its prescribed points and iterate on the individual affected tests between them. No role-prompt change is required for this distinction, and a written instruction is not proof of execution or a guarantee of success. The 2026-09-22 diagnostic runs demonstrated that existing green tests still accept the obsolete blanket link rejection and omit standalone-owner setup. Replace those contrary expectations, add the missing controls to maintained tests and the reliability catalog, and make them pass; do not treat an unchanged green suite as implementing these amendments. See `evidence/focused-diagnostics-2026-09-22.md`.

Acceptance creates one hook-free Candidate commit containing source plus Complete provenance. Existing per-path and aggregate staged-size limits, `.kogen/runtime` rejection, assume-unchanged/skip-worktree refusal, required commit trailers, and publication provenance remain enforced. An identity-bearing build lock and publication journal precede compare-and-swap advancement of `main` from the admitted ref. The controller then synchronizes the checked-out control index/worktree to that exact commit and removes the matching ignored Approved copy. Journal-proven post-ref recovery is idempotent; pre-ref, foreign, or ambiguous state is retained and refused. Failure leaves `main` and control unchanged and reports the retained Candidate locator.

The installing Build is judged by the admitted controller and byte-identical tracked entries from `.codex/hooks/**` plus `.codex/hooks.json` at admitted HEAD, bound by path, type, mode, size, and digest. Ignored runtime products such as `__pycache__/*.pyc` are excluded from the authority manifest but may not substitute for tracked entries. Controller-owned Elixir supplies new roots around that authority; this Intent does not change or hot-load the judge. Linked worktrees are structural ownership, not hostile-process containment.

## Outcome challenge

The latest Build's audit located unified state but parsed legacy fields, expected
exactly two attempts despite a legitimate third, and omitted artifacts needed
following cleanup. The unreached connected owner still used the old history
location. The two live-owner end-to-end offline controls in repair-plan section
2 must expose those failures before paid execution; loosening a count alone is
not repair. The valid injected handoff-correction control must not hide a
controller-generated citation that its own validator rejects.

The earlier Build demonstrates an additional false-positive route: unchanged
green tests can omit every newly required assertion, a fixture can dereference
links to conceal broken seed admission, a fake Reviewer can cite only the one
working path while a real Reviewer copies an uncitable advertised path, and a
successful `cp -c` can be an eager byte-copy fallback. The focused controls in
`repair-plan.md` cover these actual producer/consumer paths, including both live
owners' post-execution retention. Test names, written instructions, synthetic
environment maps and a provider-free audit archive alone do not prove behavior.

A plausible implementation could create a worktree and route role shells there while `Verification.initialize/6`, offline receipts, isolated children, or evidence snapshots still derive control paths. It could recursively copy `deps/` and `_build/`, rebuild them from scratch, or blindly trust stale cloned BEAMs, each technically satisfying only part of the outcome. It could also clone credentials, locks, or mutable session state along with a broad cache directory. All ordinary tests could pass, yet a stale control receipt could authorize Review, a cleanup failure could erase a provider timeout, or a Candidate test could exit zero without completing. Another plausible implementation could add workspace tests without updating the 312-declaration reliability catalog. The scenarios therefore require exact seed allowlisting, clone and incremental-invalidation evidence, command-level root sentinels, current receipt consumers, catalog reconciliation, and exact publication—not workspace ids or role prose.

## Appetite and non-goals

This is one cohesive Build: filesystem topology, routing, generation-aware preservation of the installed reliability authority, and atomic publication. It does not change shaping/developer/reviewer prompts; move verification out of Stop; change `.codex/hooks/**` or `.codex/hooks.json`; add kernel/Seatbelt containment; restore or cherry-pick `97109bf9`; implement automatic stash restoration or failed-Build resumption; add compatibility modes, feature flags, fallbacks, or global pruning; redesign provider retry policy; add new Make targets; or perform the later controller-verification cutover. The one-off import of the retained implementation is required work, not an excluded recovery feature.

One active Build remains the supported workflow. Concurrent Build admission, stopped-process continuation, automatic existing-work detection, status/resume commands, bringing newer main into a Candidate, and merge-conflict repair are not implemented by this Intent. The Shaper selected the existing `mix kogen.build <slug>` command for future existing-work detection and continuation, rejecting a separate resume command; that future interface is recorded in the parked briefs linked by `developer-experience.md`.

Successful Candidates are removed only after publication, control synchronization, Approved cleanup, journal settlement, evidence snapshotting, and exact ownership revalidation. Failed Candidates are retained as diagnostic evidence and never automatically reused.

## Evidence ownership

`check` owns deterministic topology, routing, receipt binding/invalidation, provider-outcome normalization, isolated completion, reliability-catalog reconciliation, failure preservation, and publication fault injection. `cold-offline` owns the real empty-private-state and Gitless provenance recipe. `live-native` owns pinned-runtime Developer/helper/resume/Reviewer cwd and discovery plus normalized native outcomes. `live-reviewer-rework` owns authenticated same-session rework in one Candidate. `live-shape-to-build` owns connected publication to the exact `main` commit. The outer target owners retain ephemeral provider observations; Review assesses the contract, Candidate, snapshots, and receipts available to it.

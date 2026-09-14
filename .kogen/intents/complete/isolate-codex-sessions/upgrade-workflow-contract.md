# Kogen-specific runtime upgrade workflow

Accepted placement: the future Developer writes
workflows/codex-runtime-upgrade.md and links it once from the repository root
README, with conditional wording such as: “When upgrading Kogen's pinned Codex
runtime, follow the Codex runtime upgrade workflow.” The README owns only that
navigation; the workflow owns the procedure. Do not copy the procedure into
shared Shaper/Developer/Reviewer prompts, execution policy, global skills, or
ordinary Shape startup. No new project AGENTS.md or automatic workflow router.

The procedure applies when a maintainer asks, for example, “Upgrade Codex to
0.155.0.” That request identifies a future upgrade task, not a reason to upgrade
in this Build or change the current selected initial candidate.

## Required maintained content

Use actual implementation paths rather than invented commands or placeholders.
Document these inputs: exact requested version, current release pin/artifacts,
current README and runtime integration contract, release notes, clean checkout
baseline, selected authenticated Kogen scope, installed tooling/dependencies,
and existing gate/evidence owners. Link to other maintained workflow owners
rather than duplicating their instructions.

Starting at the Kogen repository root:

1. Read the exact current pin and request; inspect official release changes and
   affected native capabilities. Do not silently substitute upstream latest.
2. Trace current launch, login/storage, helper, hook, stdio executor, session
   capture, profile and evidence consumers. Run bounded source-bound probes in
   authorized disposable paths when inspection cannot resolve material uncertainty.
   Preserve results and limitations; do not import personal credentials.
3. Shape one small upgrade Intent covering exact artifact/integrity changes,
   required adaptations and existing behavior preservation. Escalate consequential
   product differences to the human, while resolving engineering details locally.
   Obtain explicit approval under the ordinary shaping contract before Build.
4. Build under normal gate ownership. Keep an already-running Build bound to its
   starting runtime. Candidate-specific fixture execution must exercise the new
   pinned runtime, not accidentally count the Build's old runtime as new-version
   compatibility. Use the existing fixture context boundary and offline controls;
   no production public override or arbitrary-version support is introduced.
5. Require normal check/live results and fresh independent Review on the upgraded
   Candidate. Preserve installer integrity/failure/retry tests, scoped login,
   every-role isolation, tools/hooks, exact resume, active-runtime preservation,
   current public shaping evaluation and retained evidence. Document setup errors
   distinctly from compatibility failures. User installation runs no model tests.
6. Complete through the ordinary accepted Commit workflow. A tested pin change can
   then accompany a Kogen release under its separately authorized release process;
   Build acceptance is not publication authority. A future Kogen updater installs
   the runtime declared by that release, not arbitrary upstream latest.

Outputs: a shaped upgrade Intent, verified exact pin/artifact metadata and any
necessary integration changes, retained concise evidence, and updated tested-version
claims. Completion requires the requested release's real native acceptance and
normal Review; accepted flags, version output, fake harness tests or historical
receipts alone are insufficient. A CLI pin does not freeze hosted service behavior.

On failure retain diagnostics and the published supported pin. Fix within the
approved scope and existing resumption budget; if a new product choice is needed,
return to shaping. Do not raise retry limits, accept stale evidence or auto-publish.
Follow the existing stopped-Build inspection workflow rather than inventing resume
support. An unavailable artifact or missing authentication must not be hidden by
falling back to personal Codex or a different release.

## Verification and appetite

This is a small documentation addition to the managed-runtime feature. Use current
focused offline tests and the normal check/live targets for implementation proof;
do not add another paid live shaping case merely to test that a document exists.
Review checks the README link, the procedure's actual source/command references,
correct ownership and absence of upgrade boilerplate in shared prompts. The
existing release-pin/installer and native lifecycle scenarios own runtime behavior.
This workflow creates no approved backlog item for 0.155.0 or any later version.

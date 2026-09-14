> Decision chronology: approval limitations and pending reconciliation statements
> below describe their recorded moments. The final reconciliation supersedes
> earlier pending edits. Current lifecycle is owned by
> [the approval statement](evidence/approval-2026-09-13.md).

# Continued shaping decisions

## Explicit shaping output boundary

The Shaper corrected the controller's attempted repository implementation:
“WE CAN'T WRITE CODE IN THE REPO” and “you can write code in your intent”.
All further prototype code and experimental tests belong inside this Intent;
repository source/test edits are Build work. The controller restored its two
source modifications and moved its new test and prototype under
evidence/prototypes/denial-collector/. Earlier authority to resolve the blocker
means prove it in that isolated setting, not implement in the working source tree.

## Python patch selection follow-up

The Shaper reported installing Python 3.14.7 globally with mise and identified
it as the latest release. Updated the project mise.toml pin from 3.14.3 to the
already-installed 3.14.7 to match. Earlier 3.14.3 probe receipts remain historical
evidence; the minimum Python requirement is unchanged at 3.11+.

## 2026-09-10 visit: controller owns the engineering resolution

Provenance: after the controller asked the Shaper to select the executor workaround
or further investigation, the Shaper directed “figure out, don't stop” and “you
come to me for UX decisions”. Continue technical investigation autonomously and
select a demonstrated implementation consistent with accepted behavior. Do not
park this Intent awaiting human selection of a transport or internal process.
This authorizes investigation and engineering judgment, not silently weakening
isolation or declaring an unproven implementation accepted. Resolve or demonstrate
an actual product-level conflict before escalating. The unauthenticated TCP
candidate is not selected; investigate a private execution path first.

Controller engineering disposition after the delegated probes: select native
named stdio execution with a static managed account registry and per-launch
immutable dispatcher snapshot, as specified in REPAIR.md. Offline native probes
demonstrate ordinary CLI provisioning, parent-private skill discovery, concurrent
caller separation and child exit on owner EOF. This removes the TCP listener and
does not add public UX. Actual root/helper model catalogs, hooks and exact resume
on this route remain mandatory live acceptance, not a claim already established
by the offline probes. Preserve full scope and fail verification on regression.

## 2026-09-10 visit: provision current Python with mise

Provenance: Shaper said “I don't care about compatibility. Let's install and
require whatever is necessary”, identified mise, and explicitly requested
installation now so Build need not provision it. Require Python 3.11+ (tomllib)
and select a concrete project Python through mise.toml. No Python 3.9 fallback
or compatibility implementation is required. Project setup is explicit; ordinary
Build must not silently install tooling. Detect unsupported/missing Python clearly
instead of reporting valid native settings as unexpected. The controller may
provision the prerequisite now and record the verified version separately.
This resolves only the Python choice; executor tradeoffs remain pending.

## 2026-09-10 visit: login discoverability

Provenance: Shaper said “Let's not add interactive prompts etc.”, “let's use
flags”, and requested native forwarding be shown for kogen.codex.login so it
is not hidden. The Shaper also asked whether device authentication should be
supported. It is already part of the accepted generic native-forwarding contract;
installed 0.154.0 help confirms the flag, so document it alongside API-key stdin
and default browser login. No Kogen authentication-method parser or chooser.
Task help and README must expose `--`, scope-option placement and examples.
Native device/browser authorization is still interactive at the provider level;
no claim that device auth is unattended. This choice does not approve the Draft.

The Shaper explicitly assigned MCP investigation to another session. Leave it
there; preserve this Intent's existing isolation requirements.

## September 13: reassessment and current fixture preservation

Provenance: the Shaper explicitly directed the controller to continue after its
recommendation to reassess current main and rejected questions about routine
engineering direction. The controller completed that reassessment and selected
private operation-context plumbing for current session/evaluation consumers,
preserving existing public commands and test evidence contracts. See
[evidence/current-main-reassessment.md](evidence/current-main-reassessment.md).
This is an engineering integration decision, not a new public interface, approval,
or implementation authorization. Original shaped_against and historical
reshaped_against are preserved; this new note owns current-checkout assessment.

## September 13: accepted release-pinned Codex policy

Provenance: after the controller proposed shipping an exact version requirement
and installer with Kogen, the Shaper replied “YES!” and specified that a future
new Kogen download should install the new Codex version if that Kogen release
marks it. The Shaper explicitly prefers one selected Codex version per Kogen
release over supporting independently user-selected Codex versions.

This supersedes the earlier public update-to-latest plus user-side compatibility
verification policy. Kogen owns an exact native release/artifact integrity pin and
isolated installation; changing personal Codex or publishing a newer upstream
release does not change Kogen’s selection. Compatibility testing happens during
Kogen development before publishing a changed pin. A future Kogen updater can
install the runtime required by the downloaded Kogen release; implementing that
Kogen updater remains outside this Intent. Existing immutable active-runtime and
credential/session preservation requirements remain; supporting arbitrary versions
or a release-pair compatibility matrix is not required.

This is approval of the release-pinning choice, not approval of the whole Draft.
INTENT.md/scenarios/risks and repair/reassessment references still need a coherent
revision removing the superseded public update mechanism. Do not build from the
older update contract. The Shaper’s question about the maintainer process for a
future 0.155 release is being discussed; recommendations are not yet an approved
future Intent or a mandate to adopt every upstream release.

## September 13: keep upgrade workflow local and loaded on demand

Provenance: the Shaper delegated the document location and required that regular
shaping sessions not be bloated with rarely used, Kogen-project-specific upgrade
instructions. The controller selects workflows/codex-runtime-upgrade.md as the
future maintained procedure, discoverable through one short conditional link in
the root README. Read that procedure only when maintaining Kogen's pinned Codex
runtime. No upgrade material goes into shared role prompts, shared execution
policy, or a global skill. No project AGENTS.md is created.

The Developer will write the procedure as part of this Intent, using the actual
implemented pin/installer/test paths. Its required content and validation are in
upgrade-workflow-contract.md inside this Draft. The procedure is documentation,
not a new upgrade command, automatic release watcher, new live evaluation or
approval shortcut. This scope decision does not approve the whole Draft.

## September 13: final summary reconciliation

The Shaper accepted conditional README discovery with “ok”, then requested a
summary and said the feature seemed ready. The controller reconciled the accepted
release pin and on-demand workflow decisions throughout the active contract.
The pre-pin package text is retained in evidence/history/pre-release-pin/ as
historical evidence. The legacy verified-update scenario is replaced by
release-pinned-runtime; its installer, integrity, account and active-work
preservation requirements survive. No standalone Codex update or generic upgrade
command remains. No additional shaping visit or current approval was recorded.

## September 13: authorized post-Build repair amendment

After the controller diagnosed the failed Build and confirmed it had not amended
the Intent, the Shaper explicitly directed adding the findings. Added
[evidence/build-failure-2026-09-13.md](evidence/build-failure-2026-09-13.md) and
linked it from the contract and repair plan. This clarifies repairs within existing
requirements; identity, approval metadata, continuation history, scenarios, risks,
guarded paths and prior evidence are unchanged. No source/test/configuration edit,
Build restart or additional approval is implied.

## September 13: thorough post-failure lifecycle audit

The Shaper supplied the next failed Build and requested a more thorough plan.
The controller added [the current audit](evidence/plan-audit-2026-09-13.md),
with executed source-bound controls and an ordered integration repair sequence.
This supersedes historical repair ordering, preserves required helper kinds and
all acceptance gates, and separates deterministic integration failures from
provider interruption. Scope, approval and original/continuation metadata remain
unchanged. Only the Approved package was amended; no Build was started.

## September 14: latest failed-Build audit

The Shaper supplied Build 2xt-TMNZy1whWx2BaSUeGw0y and requested a more thorough investigation. Added the linked September 14 audit and executed focused controls within the package. This continues the existing authorized repair amendment; no scope, approval, provenance, gate or resumption change, production write or Build restart occurred. Native kind capability remains unresolved and must not be silently waived.

## September 14: executed helper capability verification

At the Shaper’s direction, root executed native baseline and two definition-loading controls; runner metadata confirms required kinds and profiles. REPAIR.md now owns the consolidated current sequence; REPAIR-history.md preserves earlier chronology. No scope, pin, approval or gate change. Production integration is not claimed complete.

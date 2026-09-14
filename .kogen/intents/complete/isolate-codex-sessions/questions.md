# Current visit — September 14, 18:59 UTC

Current approval is owned by the [September 14 statement](evidence/approval-2026-09-14.md).
Historical approvals below remain provenance. See [startup findings](evidence/continuation-2026-09-14.md).

The original baseline remains main/fdfaea11; current checkout is main/9a8e7eba.
No baseline adoption has been decided. Recommended continuation is to reconcile
current Stop ownership, schema-bound handoff transport, all seven existing shaping
evaluation cases, and bounded evidence publication, then revisit the six repair
obligations against current source. These remain engineering work; the Shaper has
now approved the package without changing settled runtime/login choices.

The Shaper subsequently asked whether to reuse the latest Isolation stash.
[Read-only stash assessment](evidence/stash-assessment-2026-09-14.md) recommends
a fresh Build on current main with selective reuse of e3d993f3, not wholesale
restoration or a full rewrite. The Shaper subsequently approved the package and proposed stash application; the
current approval statement retains the distinction between selective reuse advice
and wholesale restoration.

No new product choice has been established by startup inspection. Engineering
reconciliation and combined implementation acceptance remain unfinished. Parked
same-build-refresh, external-repository-cli, stopped-Build recovery and unrelated
shaping work remain outside this Intent and are not approved backlog.

---

The following disposition and discussion describe earlier visits.

# Current disposition

The release-pinned contract is reconciled across INTENT.md, scenarios.yaml,
risks.yaml, REPAIR.md and the current-main consumer assessment. No outstanding
product choice remains from this conversation. The Shaper accepted the dedicated
Kogen workflow document and conditional README discovery, without a separate
upgrade command or additions to shared shaping prompts.

Current lifecycle is recorded in the [approval statement](evidence/approval-2026-09-13.md).
The earlier “ready” and summary request were not approval. Future Build acceptance
still requires explicit installed/authenticated
setup and current check/live evidence; historical probes are not acceptance.
Original provenance and one continuation entry for this visit remain unchanged.

The September 10 discussion below is historical. Its update-to-latest and
user-side compatibility runner requirements are superseded by the release-pinning
decision in decisions.md. Other accepted isolation/login/repair choices remain.

---

> Historical visit (2026-09-10T09:50:00.754357Z): the Shaper explicitly approved
> the revised draft with “and yeah I approve”. See evidence/approval-current-visit.md.
> Earlier approval statements below retain their historical provenance.

# Resolved decisions and retained limits

The Shaper reviewed the revised feature summary and explicitly replied
“Ok, approved.” This is the final managed-runtime revision of the same Intent;
the earlier Approved contract is historical, not the source of current authority.

## Resolved

- Explicit install; no automatic installation by shape/build.
- Native delegated login, with no Kogen-owned authentication-method UI or API-key
  flag. Kogen scope flags select storage; the standard forwarding separator
  preserves access to native options without interpreting authentication methods.
- Fresh separate Kogen authentication. Personal credential import/copy/sync is
  superseded after the token-refresh and synthetic-file investigations.
- Shared Kogen login by default, with explicit project override for work/personal
  separation; missing project login never selects another account. The proposed
  scope commands are included in the reviewed feature's concrete contract.
- Explicit update/status, verification before default activation, retained runtimes
  for active Builds and no background updates during ordinary work.
- Fresh Build from the clean current baseline; the Shaper stashed the failed
  implementation. Do not restore it wholesale or resume its exhausted conversation.
- General shaping improvements are a separate future shaping session, not part
  of this Build. The copyable prompt lives in the local reshaping receipt area.

## Evidence and implementation limits

- Native relocation and synthetic login/logout were observed on macOS arm64
  Codex 0.154.0. Earlier private-HOME/auth-link probes used 0.153.4. Neither is a
  rule rejecting other version strings or a guarantee of future compatibility.
- Existing login documentation describes default browser login and separate native
  options. No probe established that the interactive login menu offers every
  authentication method. Kogen delegates native behavior and does not invent a
  menu to make that assumption true.
- No real account credentials were copied or forced through refresh in the new
  probes. Native local status cannot prove remote access, available models or
  remaining subscription/API allowance.
- Copying a ChatGPT token bundle is not a new independent login. Shared local
  credential ownership does not isolate account-wide revocation or provider policy.
- Managed installer tests verified complete-tree relocation, not a finished atomic
  updater. Build must implement and test integrity, safe staging, selected runtime
  lifetime and activation through the declared scenarios.

## Testing cost and ownership

The Shaper asked how much this increases testing. The controller explained that
safe update and account selection add a meaningful offline matrix; the old live
suite took approximately seven minutes per attempt and no new duration is yet
measured. Failure, retry, integrity, account routing and concurrency permutations
must remain offline. Reuse one bounded real compatibility runner for public update
and live acceptance, not the full repository gate or an exhaustive release-pair
matrix. Cache downloaded immutable artifacts if useful, not gate results. A latest
release check belongs to explicit update; offline tests must not depend on current
upstream releases or installed personal credentials.

No unresolved user choice is intentionally delegated as permission to invent a
restriction. If implementation reveals a material conflict with these decisions,
report it as a shaping issue; do not silently weaken scope or verification.

## Current continuation: unresolved checkout reconciliation

Source: fresh-continuation startup instructions dated 2026-09-10T09:50:00.754357Z
and read-only `git status --short` / `git rev-parse HEAD` during this visit.

- Original shaped_against remains main/fdfaea11. Current HEAD is main/bf68fd70,
  matching the prior recorded reshaped_against; no new baseline decision is made.
- The working tree is not clean: managed-runtime modules, public Codex tasks,
  hooks, launch integration and tests have tracked modifications or untracked
  additions. This conflicts with the retained expectation of a fresh Build from
  a clean baseline and a failed implementation remaining stashed. Their origin,
  acceptance and intended disposition have not been established in this visit.
- Ask the Shaper where to continue and whether to reassess the draft against
  these existing changes. Do not infer authorization to restore, discard, build
  or accept them. No implementation files were changed by this visit.
- The draft retains twelve scenarios and four shared risks. Current Makefile
  declares both requested targets, check and live; configuration retains two
  outer resumptions. No implementation verification was run in this visit.

## Login discoverability and latest failed Build

Source: Shaper's screenshot and failure report in this visit; see
[evidence/login-and-build-followup.md](evidence/login-and-build-followup.md).
The Shaper confirms another Build failed, explaining existing implementation
changes. They are unaccepted work, not evidence of completed scenarios.

Resolved by the Shaper in this visit: keep native forwarding and flags, add no
interactive prompts/chooser, and expose the forwarding methods in task help.
See decisions.md for provenance and device-auth treatment.

The latest failed live gate encountered a missing managed runtime. Before another
Build, reconcile explicit user setup with live-fixture prerequisites; preserve
no automatic login/import and do not mark nine unverified final scenarios ready.
See the linked follow-up evidence for the exact observed assertion and limits.

## Build bootstrap gap: pending disposition

The new live fixtures require a persistent managed installation and authenticated
Kogen scope. The Build creating those capabilities began without that setup.
The Developer could implement the feature but could not satisfy native login
prerequisites under the retained explicit-user-setup/no-personal-import contract.
The two outer resumptions did not change that external prerequisite.

Recommendation pending agreement: keep explicit setup; make the required setup
for native acceptance clear, establish it before a subsequent Build, and avoid
spending retries on unchanged setup failures. Any general change to Build retry
policy or handoff diagnostics needs a separate scope decision, not an implicit
expansion of this Intent. Installation is now shown by the Shaper's screenshot;
successful login and all live acceptance remain unestablished here.

MCP investigation is handled in another session per the Shaper; do not investigate
or repair it in this continuation. Existing isolation acceptance is unchanged.

## Approval and current retry status

The Shaper approved the revised draft in this visit and explicitly owns the
stash/start/pop workflow. No further decision about that workflow is requested.
Saved shared ChatGPT login and runtime execution were confirmed. Kogen status
itself fails because it rejects shared-store config.toml; file provenance remains
unresolved. See evidence/approval-current-visit.md. Do not erase the file or relax
isolation by assumption. Authentication setup is no longer merely unconfirmed;
wrapper readiness and native acceptance still require resolution.

## Repair investigation: pending human choices

Current disposition: no human engineering choice remains. Python is provisioned;
the controller selected native named stdio execution after the delegated native
probes. REPAIR.md is the current repair direction and distinguishes demonstrated
feasibility from model-driven Build acceptance still required. The historical
questions below are superseded, not instructions to ask the Shaper again.

Superseding steering: the Shaper subsequently directed the controller to resolve
the executor engineering autonomously. The questions below preserve chronology;
neither Python nor executor selection is awaiting a human answer. Python is
settled; execution feasibility remains active controller investigation. See
decisions.md. Do not repeat the architecture-choice question.

Source: the Shaper requested thorough investigation after the next failed Build,
then asked for the shaping-quality failure history and probing/delegation status.
See [REPAIR.md](REPAIR.md) and [observed probes](evidence/repair-probes.md).
These findings supersede the earlier provisional config-file diagnosis above.

- Python: preserve the existing Python 3 baseline (including this host's 3.9), or
  explicitly require 3.11+ with clear detection/selection? The current validator's
  missing tomllib is misreported as unexpected settings. With Python 3.14 the
  existing recognized projects/tui configuration passes; deletion is not needed.
- Executor: accept the demonstrated temporary native local executor, including
  its unauthenticated loopback endpoint, explicit process ownership and changed
  tool-level alternate-shell support, or require another mechanism? Root/helper/
  hook environment and exact resume were demonstrated with production-like flags.
  This is feasibility evidence, not acceptance of those tradeoffs or a full gate pass.

Both choices were presented during investigation. Subsequently the Shaper explicitly
authorized requiring/installing necessary Python with mise, without compatibility
work; Python 3.11+ is accepted. See decisions.md. Executor feasibility remains
controller-owned investigation, superseding the earlier request for a human choice.
The Shaper
owns stash/start/pop; no further workflow permission is needed. Focused probing is
complete for the earlier repair candidate; further private-execution investigation
is active. The repair must not be called ready before its mechanism is demonstrated.
No production fixes or full Build were performed by
this shaping investigation.

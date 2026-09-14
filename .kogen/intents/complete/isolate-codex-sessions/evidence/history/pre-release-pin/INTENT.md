> Latest shaping decision: release-pinned Codex is accepted; see
> [decisions.md](decisions.md#september-13-accepted-release-pinned-codex-policy).
> The previous public update-to-latest contract below is superseded and awaits
> reconciliation. This package remains unapproved.

> Current state — September 13, 2026: this package remains an unapproved Draft.
> [Current-main reassessment](evidence/current-main-reassessment.md) is part of
> the contract and owns current consumer integration and evidence requirements.
> Original provenance and historical approvals remain unchanged; no approval
> or Build acceptance is claimed for this conversation.

> Historical visit (2026-09-10T09:50:00.754357Z): the Shaper explicitly approved
> the revised draft with “and yeah I approve”. See evidence/approval-current-visit.md.
> Earlier approval statements below retain their historical provenance.

# Manage isolated Codex runtimes and logins

Current repair investigation: read [REPAIR.md](REPAIR.md) and the
[focused probe evidence](evidence/repair-probes.md) before another attempt.
Python 3.11+ and explicit mise provisioning are now accepted (decisions.md).
The Shaper directed the controller to resolve execution internals autonomously.
The resulting repair uses native private-pipe execution with no listening port;
REPAIR.md specifies the mechanism and remaining Build acceptance. Earlier approval
and original provenance remain unchanged.

Historically, the Shaper approved the revised managed-runtime summary with
“Ok, approved.” in the September 10 continuation. [Approval provenance](evidence/approval.md) records
which earlier choices this revision supersedes. This package is one coherent
runtime integration Build, not a general installation manager or shaping-process
redesign. Read [scenarios](scenarios.yaml) and [risks](risks.yaml) together.

## Outcome

Kogen must work independently of the user's ordinary Codex installation,
configuration and login. Users explicitly install Kogen's runtime, authenticate
through Codex itself, and then shape/build with unchanged ordinary commands.
They can update personal Codex without changing Kogen, and explicitly update
Kogen's Codex without replacing the runtime under active work. A shared Kogen
login is the default; projects can select a separate login for work/personal use.

## Public command contract

Commands run from a Kogen-enabled checkout through the existing Mix-task entry
model. Shared login means Kogen-owned storage shared across checkouts; this Intent
does not install a global Kogen CLI or implement arbitrary-project installation.


- `mix kogen.codex.install`: install the initial release selected and tested by
  this Kogen release for the supported host. Show the release, download/install
  progress and result. Do not install the user's PATH Codex or alter shell startup
  files. Repeated install verifies/reuses an intact installation, without updating
  it, resetting credentials or removing sessions. A failed/partial install can be
  retried. Installation does not authenticate or launch a model; finish with the
  login command when authentication is missing.
- `mix kogen.codex.login`: run the managed runtime's native `codex login` against
  the shared Kogen credential scope. Delegate terminal interaction, browser/device
  flow, stdin and exit status. Kogen does not own an authentication-method menu,
  a subscription/API-key option, token parsing or a second login implementation.
  Native arguments following `--` are forwarded unchanged; wrapper parsing is
  limited to Kogen's scope selection. Do not claim that a particular native login
  menu contains choices not demonstrated by that installed CLI.
  Kogen adds no interactive authentication chooser or confirmation prompts.
  Make native forwarding discoverable in `mix help kogen.codex.login` and README:
  show default browser login, `mix kogen.codex.login -- --device-auth`,
  `printenv OPENAI_API_KEY | mix kogen.codex.login -- --with-api-key`, and
  `mix kogen.codex.login -- --help`. Explain that Kogen scope options precede
  `--`, native options follow it, and `--project` works with these methods.
  Help must be available before managed installation or authentication and must
  not start login. Device auth remains native ChatGPT authentication requiring
  human authorization; API-key stdin supports unattended credential provision.
- `mix kogen.codex.login --project`: select a private project credential scope and
  invoke the same native login there. Record explicit project selection before
  login; if login is cancelled/fails, that project remains selected but unauthenticated,
  rather than silently using the shared account. Require a project checkout.
- `mix kogen.codex.login --use-default`: explicitly remove this project's login
  override and select the shared Kogen login. Report the scope change; do not
  initiate login, delete credentials or rewrite the shared account. Conflicting
  scope options are errors before side effects. Default login and project login
  affect only their selected scope, never ordinary Codex credentials.
- `mix kogen.codex.status`: report installed/default release and actual retained
  active-runtime use, plus the effective credential scope in this checkout and
  native login configured/not-configured result. Do not print secrets, invent account identity, claim remaining allowance
  or treat local login status as proof of remote/model access. It must be useful
  before installation and must not install, log in or call a model.
- `mix kogen.codex.update`: explicitly resolve the latest stable official release,
  stage it alongside the working runtime, and verify the Kogen integration before
  activation. Use the current checkout's effective project-or-shared credential scope. Show
  old/candidate releases and progress; explain before verification
  that it uses the selected Codex account. On success new work uses the candidate;
  failure retains the working default and reports the failed stage/evidence.
  Already-current is a no-op. If login is missing, report the login command rather
  than opening login or silently choosing other credentials. No background updater.

`shape` (fresh or draft continuation) and `build` check the managed installation
and selected login before starting provider work. Missing installation reports
`mix kogen.codex.install`; missing selected credentials reports the appropriate
login command. They do not install, open login or fall back to personal Codex.
Preserve existing clean-worktree, branch, package and hook preconditions. Do not
claim all network access/entitlement failures can be predicted by local preflight.

## Runtime acquisition and upgrades

Use a Kogen-owned, versioned user-local installation outside the repository and
iCloud. Exact internal paths are implementation details; status/errors identify
the relevant paths when needed. Preserve the complete native platform distribution,
not a symlink to a mutable personal installation or a copied Node entry script.
The bounded probe demonstrated native-tree relocation for macOS arm64 0.154.0.
Use that as the initial candidate and establish full compatibility in this Build's
live gate before documenting it as tested. Preserve the repository's macOS scope. Select the official native artifact for
the host architecture and cover selection offline; this probe establishes live
behavior only on arm64. Do not reject an otherwise available macOS distribution
solely because this host did not exercise it. Report genuinely unavailable
platform/artifact support before mutation rather than claiming cross-platform proof.
Do not introduce an end-user Node/npm prerequisite merely because npm acquired
the probe package; native execution worked without Node.

Acquire official release metadata and exact platform artifacts, verify the
advertised integrity, validate archive paths/types before extraction, and stage
privately before promoting a complete immutable installation. Reject incomplete,
corrupt or unexpected existing occupants without overwriting unrelated files.
Kogen owns its install manifest/version metadata. Do not identify compatibility
by equating every version string or parsing Codex's private session-file schema.

Select a concrete installed runtime at Shaping/Build entry. Carry it through all
Developer, Reviewer and exact-resume launches in that Build, with native helpers
using the same distribution. Selection must survive changes to PATH and the default
runtime pointer; an absolute path to a mutable global symlink is insufficient.
Retain old installations and session data; no automatic garbage collection or
migration is in this Build. Protect active use and atomic default activation,
without replacing the existing Build lock or adding a general job scheduler.

Implement one direct internal compatibility-runner boundary receiving the staged
absolute runtime and the explicitly selected already-configured Kogen credential
scope. It bypasses default selection only for this owned candidate verification;
it does not invoke public install/update tasks or silently choose fixture/personal
credentials. Offline tests inject native-status/launch stubs. Real compatibility
verification uses a previously authenticated selected Kogen scope and private
fixture configuration/session state, without browser login or credential copying.

Update verification must exercise actual candidate native behavior with private
fixtures: interactive Shaping, authenticated exec, native helper, tracked hooks,
failed-check correction, exact Developer resume and independent Review. Test the
isolation positive/negative controls. Reuse a bounded compatibility fixture/runner
with the live suite, not a second divergent set of rules. Do not recursively call
install/update or the whole live gate from a fixture check, and do not mutate a
real user's project for compatibility verification. Settings/session storage for
active work cannot be rewritten by update verification. Fresh work gets fresh
sessions; continued shaping reads a Draft, not an old provider conversation.

## Authentication boundary

Require the selected Kogen scope to be configured through native login before
provider work; reuse that login on later launches rather than asking users to
reauthenticate each time. Initial authentication is a fresh Kogen login, not an
import of a personal session. No personal credential copying,
symlinking, continuous synchronization, automatic account selection or migration.
One Kogen credential scope is shared by default; project-specific scopes are
explicit and persist privately. The source of that selection is separate from
throwaway verification/session data, so losing a session directory cannot silently
change the chosen account. Report missing selected credentials without fallback.
Project account preference is local/private, not team-tracked secrets or automatic
mutation of the tracked Kogen configuration. Runtime files, credentials, private
preferences and raw session data never enter commits.

Codex owns credential format, login methods, persistence and refresh. Kogen selects
its owned scope and delegates; no JSON token-field validator or copy of provider
login code. Preserve native authentication capabilities through delegation, with
no Kogen-owned `--with-api-key` flag or subscription selector. Scope isolation must
also prevent inherited API/provider environment overrides from silently choosing
a different account. Installation and status perform no billable model calls;
ordinary work and explicitly requested update verification use the selected account.

Account-wide revocation, workspace policy, provider availability and allowance are
not isolated by local credential storage. Native login/status failures are surfaced
without leaking tokens. User cancellation remains a cancellation, not success.
Do not promise that local login status proves usable credentials or model access.

## Configuration, ordinary tools and lifecycle invariants

Every root role and helper must exclude personal settings, instructions, skills,
rules, hooks, plugins/apps, MCP configuration, memories and sessions. Retain project
guidance/skills and Kogen's tracked hooks. Resolve needed caller tool state before
constructing private HOME, CODEX_HOME and relevant XDG discovery locations; exclude
personal parent-config discovery and provider/session attachment overrides. This
is automatic context/config isolation, not an OS/filesystem security sandbox.

Regenerate recognized Kogen settings at launch; keep retained sessions separate.
Restore the caller's ordinary HOME and set/unset XDG environment for shell tools
and tracked checks, while retaining Kogen-owned Codex storage. Hooks need their
own restoration because native shell environment policy did not restore hook HOME
in the earlier probe. Keep one environment owner, preserve direct hook invocation,
and do not write settings underneath another active invocation.

Preserve configured root/helper model and effort without substitution. Preserve
Developer/helper gate prohibitions, Stop-owned Check, outer-owned non-check targets,
structured handoff and attempt binding, tracking integrity, fresh independent
Review, findings and the existing two outer resumptions. Login/install/update
must not become a Developer bypass around gate ownership. No reviewer or Shaper
acquires Developer-only Stop checks.

## Appetite and non-goals

One Build: implement the smallest cohesive managed-runtime boundary, its five
public commands, scoped native login, all-role launch integration and focused
extensions of the existing offline/live fixtures. Prefer small shared modules;
do not build a generic package manager, independent authentication platform,
background updater or general compatibility service. Do not relax requirements
silently to fit the budget; report a material implementation-discovered product
decision rather than inventing a lockout or fallback.

No new providers, containers, arbitrary-project Kogen installation, personal
plugin repair, private-session migration, automatic credential imports, runtime
cleanup UI, account/billing UI, stopped-Build recovery, larger resumption budget,
project AGENTS.md creation or general shaping-process improvement. The old failed
implementation remains stashed reference, not an accepted Candidate to reapply.

## Current integration and acceptance

Apply [the current-main reassessment](evidence/current-main-reassessment.md)
alongside REPAIR.md. It maps the newer public shaping evaluation, native session
capture and required-evidence consumers into the existing scenarios. Preserve
all five cases, managed context through fixture replies, configured profile
audits, outer-owned interaction audits and independently inspectable receipts.
Offline rehearsal must cover those combined routes before real acceptance.
Do not restore older fixtures from the failed implementation or prototype.

## Navigation

- [Identity, provenance and permitted paths](intent.yaml)
- [Acceptance scenarios](scenarios.yaml)
- [Lifecycle and compatibility risks](risks.yaml)
- [Resolved decisions and evidence limits](questions.md)
- [References](references.yaml)
- [Approval history](evidence/approval.md)
- [Managed installation probe](evidence/managed-install-probe.md)
- [Authentication investigation](evidence/oauth-copy-investigation.md)

## Maintainer upgrade workflow

The Developer must add the Kogen-specific, on-demand procedure specified in
[upgrade-workflow-contract.md](upgrade-workflow-contract.md), with one conditional
root README link. Shared role prompts and ordinary shaping startup must not
contain or automatically load that procedure. The future procedure uses the
implemented pin, fixture and verification paths; no automatic Kogen updater or
additional paid shaping evaluation is included.

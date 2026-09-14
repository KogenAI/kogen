Current failure guidance: [September 14 audit](evidence/build-audit-2026-09-14.md). It supersedes earlier current-failure diagnoses; prior evidence remains historical.

# Repair plan for the next Build attempt

**Current entry point:** [operation lifecycle audit and ordered repairs](evidence/plan-audit-2026-09-13.md).
It supersedes repair ordering below. The remaining diagnoses and prototype claims
are historical observations, not a claim that only one failure remains today.

## Historical repair chronology

Latest guidance: [September 13 Build failure amendment](evidence/build-failure-2026-09-13.md)
identifies concrete context serialization and fixture-caller defects. Read it
before the earlier failed-Candidate/prototype chronology below.

Read [current-main integration](evidence/current-main-reassessment.md) first.
The failed Candidate referenced below is absent from current main; historical
prototype success does not mean this checkout contains the repair. Integrate
the mechanism with current consumers and preserve newer fixture conventions.

Current proof: the denial collector prototype under
evidence/prototypes/denial-collector/ passed 17 focused offline tests and one
complete native compatibility probe (212.1 seconds), including actual denial
capture, root/helper/hook environments, discovery, exact resume and internal
fixture Review. See its results.json and README.md. This was an isolated shaping
experiment, not a Build or approval. Production source was restored after an
incorrect attempt to edit it during shaping. Build must integrate the proven
prototype and perform its own acceptance; no source fix is already installed.

Release-pinning revision: retain the executor, denial, PTY and evidence repairs
as native verification requirements. The compatibility runner is now test-owned;
there is no public update command or user-side paid verification. Historical
Build/probe observations below retain their original scope and limitations.

Latest Build update: the named stdio integration now has real passing environment,
discovery, helper, resume and internal Review evidence. The final remaining failure
is the blocked-gate evidence collector searching stdout JSON while native denial
appears on stderr. Read [latest diagnosis](evidence/fourth-build-failure.md) first.
That evidence path has now been prototyped and verified inside the Intent.
Earlier mechanism guidance below explains the implemented direction, not a request
to replace it or restart its investigation.

Read this with INTENT.md and evidence/repair-probes.md. This repairs the same
managed-runtime Intent; it does not approve a new scheduler, authentication system,
MCP repair, resumption feature, or extra outer attempts. The Shaper controls the
stash/start/pop workflow. No automatic Build was started during investigation.

## Why the earlier shaping was insufficient

The requirements already named caller environment restoration, native helpers,
tracked hooks, interactive Shaping and resume. The probes established primitives
on an earlier runtime, not their combined behavior in the actual launcher. Managed
installation and update enlarged the scope without a corresponding production-like
compatibility probe. The first Build also lacked authenticated managed setup.
Later recommendations to retry established installation/login, not readiness of
the implementation. These were shaping/evidence gaps, not permission to weaken
acceptance now.

## Resolved engineering direction

Require Python 3.11+ and use the project mise selection (3.14.7 installed and
verified). The Shaper explicitly authorized provisioning and no compatibility
work, then directed the controller to resolve execution internals autonomously.
See decisions.md. Existing public commands, scopes, login, model/effort and
verification requirements remain in force; no new user-facing executor setting.

Use native named stdio execution. Do not ship the unauthenticated TCP candidate.
The exact native runtime provisions this through environments.toml for ordinary
CLI exec; offline app-server probes establish private discovery, concurrent
environment separation and owned-process exit. The earlier real TCP probe proves
native execution can supply correct root/helper/hook environments and exact resume,
but is not a full model-driven proof of the named stdio route. The existing live
compatibility runner must establish that final integration before acceptance.

## Private execution without a listening service

Maintain a static, recognized Kogen-owned environments.toml in each selected
Kogen CODEX_HOME: default environment kogen, include_local false, and a single
program-based environment. Its stable dispatcher executes an entrypoint named
by an authoritative per-launch environment variable. For example, /bin/sh with
`-c` and `exec "${KOGEN_CODEX_EXECUTOR_ENTRYPOINT:?missing managed launch context}"`.
Do not interpolate caller values into executable shell text. The shared TOML must
contain no checkout path, runtime version, caller HOME/XDG or credentials.

Preparation creates an immutable executable entrypoint snapshot under the private
invocation generation, and supplies its path plus the selected absolute native
executable through authoritative launch variables. The snapshot validates required
markers, restores caller HOME and exact present/absent XDG values, retains selected
Kogen CODEX_HOME and role/project/target context, then execs the selected native
binary with `exec-server --listen stdio`. The model process retains private HOME/XDG.
Sanitize inherited provider, remote attachment and executor overrides before
injecting managed values. Missing/invalid launch markers fail clearly; no personal
binary, default-runtime re-resolution or network-executor fallback.

The registry is static across concurrent invocations; distinct inherited markers
and immutable snapshots supply their settings. Do not rewrite a shared registry
with per-invocation values. Preserve recognized identical bytes, refuse unexpected
occupants/symlinks, and handle incompatible managed registry revisions explicitly
without rewriting state needed by an active operation. Login/refresh and sessions
retain native ownership. The entrypoint remains Kogen-owned, never a user-editable
seed; generated snapshots remain private/untracked and are retained while active.

Native owns its stdio child and the existing Kogen launch owner owns the native
process tree. Use bounded cleanup on normal exit, failure and cancellation; retain
diagnostics and reap only owned processes. EOF cleanup was demonstrated for stdio,
unlike the rejected WebSocket service. Test crash/startup failure and descendants;
no persistent service, port allocation, global daemon or new scheduler is needed.

Before full live acceptance, demonstrate login/non-login shell environment,
root/helper/Stop receipts, project/personal context controls, actual PreToolUse
denial, explicit shell selection and exact resume in the same named stdio path.
Keep configured native helper profiles. Native app-server skills/list is useful
feasibility evidence but does not substitute for the actual model/helper catalog
assertions. Preserve public login/status behavior and concurrent launch controls.
Do not add probe-only ignore-user-config/ephemeral flags as isolation shortcuts.

## PTY driver repair

Retain terminal query handling. Treat a terminal EIO at marker/exit as a possible
exit race and poll waitpid(WNOHANG) before signaling. Bound both execution and
cleanup with monotonic deadlines. If owned group signaling fails, preserve that
diagnostic and use a safe direct-child fallback while it remains unreaped; handle
failure on either TERM or KILL. Never block forever in waitpid after signal denial.

Write a structured receipt in an unconditional finalizer, including marker,
native exit if known, cleanup attempts/outcome and timeout/permission errors.
Success requires the response marker and demonstrated cleanup, not marker alone.
An interactive process deliberately terminated after its answer can have a signal
exit. Keep descendants under the existing ownership mechanism and verify they are
cleaned under the native fixture owner; cleanup cannot rely on a vanished parent.

Negative controls: natural immediate exit after marker; quiet process ignoring
INT/TERM; no marker; group EPERM; total denial; missing/unwritable receipt; a
remaining descendant. Preserve meaningful failures and original evidence.

## Shaping fixture and provenance repair

Strengthen current continuation instructions to preserve original blocks through a
minimal edit and parse YAML before saying a continuation was saved. Do not create
another visit entry during correction. Keep incomplete drafts valid work in progress.

The Expect driver must parse before copying its continuation snapshot or issuing
scripted approval. On malformed output, retain the failed snapshot and diagnostic,
ask the same live Shaper to repair it within a small explicit fixture-only correction
bound, then parse and apply the unchanged original-provenance/one-continuation
assertions. Exhaustion remains a real failed test. Do not overwrite the output with
a canned correct fixture or make the public Shape launcher auto-repair drafts.
This does not enlarge Build's outer-resumption budget or approval authority.

## Python and configuration diagnostics

Honor the Shaper's chosen Python baseline throughout production helpers. Detect
missing/unsupported interpreters or parser dependencies as those failures; do not
label all subprocess errors as unexpected user settings. Test public status and
launch under the declared interpreter baseline, with the existing native
projects/tui bookkeeping and unrecognized-content controls. Do not delete shared
config.toml, credentials, or sessions to make readiness pass, and do not accept
arbitrary configuration content because a parser failed.

## Keep repair signal focused

Developer may use focused non-gate tests/probes before handing off, within existing
permissions. Fix the environment/PTY/YAML causes first, then let Stop own check and
outer Build own live. Preserve failed-stage receipts in compatibility evidence so
“incomplete_compatibility_evidence” does not hide which condition failed. Report
root/helper environment mismatches and internal Reviewer reasons explicitly.
Do not add a new generic verification target, run aggregate gates recursively,
raise the outer budget, or relabel incomplete claims ready.

Existing permitted paths cover these modules, native helper scripts, prompts and
test fixtures. A general Build contract/diagnostic redesign is not required to fix
this Intent; the ready/incomplete transition can retain its current ownership.

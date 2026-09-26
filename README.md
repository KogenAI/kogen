# Kogen

**Shape the feature. Leave the build to Kogen.**

Make the product and UX decisions that define the feature. Specify technical decisions when they matter. Kogen handles the implementation, checking, independent review, rework, and resulting commit.

Kogen is being built from a small core that can shape and build further changes
to Kogen itself. The aim is to grow the rest of the product through that loop:
shape the next feature, approve its Intent, and let Kogen carry out the Build.
The core is a starting point, not the finished product.

The core runs inside this repository through one pluggable harness interface
with two adapters: Claude Code (`harness: claude`) and Codex CLI
(`harness: codex`). `.kogen/config.yaml` names one or more routes, each
assigning every role a harness and a model profile; a Shape or Build selects
one route, by default the configured `default_route`. This repository's
`default_route` is `claude`. The `claude-dominant-adversarial-codex` route lets
Claude Code shape and develop while Codex reviews and answers Expert
questions; `codex-dominant-adversarial-claude` is its mirror image. Installing
Kogen into arbitrary projects and other harnesses are future work.
The broader design remains a longer-term direction, open to change as Kogen develops.

This repository is being opened quietly so the ongoing work and its history
can be inspected. Kogen is Almir Sarajčić’s personal engineering project.

## Get started

Use Elixir 1.20 with Erlang/OTP 29, Git, Make, and Python 3.11 or newer on macOS. Kogen manages the complete native runtime of each harness itself; personal Claude Code, personal Codex, and Node are not prerequisites. The pinned managed releases are Claude Code 2.1.281 and Codex 0.156.1. macOS arm64 is the live acceptance target; the official macOS x64 artifacts are selectable but have not been exercised on this host. Provider-backed work uses your selected Kogen login for the harness a route names, separate from any personal login. `mix kogen.build` also needs a macOS Keychain generic password for service `dev.kogen.jev` (the TypeSafe API key that Jev reads Developer notes with); add it with `security add-generic-password -s dev.kogen.jev -a <account> -w` before building, or Build stops before launching the Developer.

From a checkout whose `default_route` uses Claude Code:

```sh
mix deps.get
mix kogen.claude.install
mix kogen.claude.login
mix kogen.claude.status
make check
mix kogen.shape
```

A hybrid route needs both harnesses; before `mix kogen.shape --route
claude-dominant-adversarial-codex`, also run `mix kogen.codex.install`,
`mix kogen.codex.login` and `mix kogen.codex.status`.

For a route with `harness: codex`, use `mix kogen.codex.install`,
`mix kogen.codex.login` and `mix kogen.codex.status` instead — pass
`--route <name>` to `mix kogen.shape`/`mix kogen.build` to run a session on
that route, or set it as `default_route`. See
[Choosing a route](#choosing-a-route).

Describe one feature. As the Shaper, discuss its behavior and tradeoffs with Kogen’s Shaping Controller, inspect the Draft it writes, and explicitly approve it in that conversation. Approval moves the Intent from `.kogen/intents/drafts/<slug>/` to `.kogen/intents/approved/<slug>/`.
The controller may also reconcile narrow current approval bookkeeping inside the
package at that point. It preserves agreed requirements, identity, provenance and
historical evidence; a legacy `status: draft` field is harmless once the package is
selected from `approved/`, but a genuine current pending-approval contradiction is not.

To continue a saved Draft in a fresh conversation, run:

```sh
mix kogen.shape <draft-slug>
```

Kogen uses current shaping instructions and configured profiles, preserving the
Draft’s identity and original provenance. The controller reads its saved context,
summarizes unresolved work, and asks where to continue. Continued saves record a
separate shaping visit; changed Git baselines require discussion. Approval must
be explicit in this new conversation. Only drafts can be continued.

Exit the shaping conversation, then build its chosen slug:

```sh
mix kogen.build <slug>
```

Start Build on a clean branch with a commit at HEAD. Kogen implements the approved feature, runs verification, obtains an independent review, and commits the accepted result with its completed Intent and evidence. A stopped Build returns an error and keeps its work available for inspection. Review the error and working tree before starting again. `mix kogen.build` needs a macOS Keychain generic password for service `dev.kogen.jev`, the TypeSafe API key Jev uses to read the Developer's handoff notes; add it with `security add-generic-password -s dev.kogen.jev -a <account> -w`. Without it, Build stops before launching the Developer. Once running, Build sends the Developer's notes and the contract's scenario, risk, and finding IDs to TypeSafe; it never sends the diff or Candidate files, although the notes themselves may quote code.

Every Build runs in its own Candidate: a linked Git worktree at
`<workspaces-root>/<project-id>/<slug>-<build-id>/`, on branch
`kogen/<slug>/<build-id>`, outside the invoking checkout. `<workspaces-root>`
is `~/Library/Application Support/Kogen/build-workspaces`, or
`KOGEN_WORKSPACES_ROOT` when set. Each Build also gets its own harness home,
`<workspaces-root>/<project-id>/harness/<build-id>/`, and an owner record at
`<workspaces-root>/<project-id>/candidates/<build-id>.json`. The Candidate
receives a plain copy of control's `deps/` (admission stops and names `mix
deps.get` if `deps/` is missing, never falling back to the network), no
`_build/` (it compiles cold), and the controller's frozen Approved package
bytes; nothing else from control's ignored state. Shaping keeps working in
control while a Build runs — saving Drafts, editing other packages,
approving one — because those paths are ignored and never dirty control; an
edit to a tracked control file still makes publication refuse. Publication
commits in the Candidate, then, only if the admitted branch has not moved
and control is clean, fast-forwards it there (`git merge --ff-only`) and
removes control's ignored Approved copy of the slug, the Candidate worktree
(`git worktree remove`, never `--force`), its branch (`git branch -d`) and
its owner record; the harness home is kept as session evidence. A refused
publication keeps the Candidate, its branch and the harness home, and the
Build's exit message names `mix kogen.candidates.remove <build-id>
--discard-accepted`. Any other stop keeps the same three and names `mix
kogen.candidates.remove <build-id>`. If cleanup after a successful
fast-forward is refused (for example an untracked file left in the
Candidate), publication itself still stands: the Build exits zero with a
warning naming the kept worktree and `mix kogen.candidates.remove
<build-id>`. `mix kogen.candidates` lists this project's Candidates (build
id, slug, title, status, start time, branch, path); `mix
kogen.candidates.remove <build-id> [--discard-accepted]` force-removes one
worktree, its branch, harness home and owner record, refusing a `running`
Candidate and, without the flag, one holding a commit unreachable from its
admitted branch. Neither command prunes. Still one Build at a time: the
global `.kogen/build.lock` stays in control.

## The loop

- **Shaper** is the human who shapes the feature with Kogen and approves the Intent.
- **Intent** captures the shaped feature precisely enough for Kogen to build it autonomously.
- **Build** implements, checks, independently reviews, and reworks when necessary.
- **Commit** records the checked and accepted implementation of one Intent.

Verification is owned by the Build controller, not by the Stop hook. After each
Developer turn ends, the parent controller — trusted code the Build started
with, never code loaded from the Candidate — computes the Candidate id itself
(a private-index Git write-tree, refusing assume-unchanged and skip-worktree
entries) and runs `make <target>` for exactly the union of the approved
contract's `verified_by` targets, in catalog rank order, as child processes in
their own process group, outside the Developer's process tree. Each finished
target gets a Candidate-bound receipt recording the target, status, exit code,
Candidate id, attempt token, context sha256, catalog sha256, cycle sequence,
start and finish time, elapsed milliseconds, the output log path and its
sha256, and cleanup status. Within one outer attempt, a later cycle reuses only
a `provider_backed: true` target's earlier *passed* receipt when the Candidate
id and catalog digest are byte-identical, marking it `reused_from` the cycle it
came from; every `provider_backed: false` (offline) target runs fresh every
cycle, whatever its name. `verification_retries` bounds a failed controller
verification by resuming the exact same Developer session — never launching a
fresh Developer — inside the same outer attempt; those retries do not consume
the outer allowance, and exhausting them stops the Build ahead of other
routing. The controller is also the only writer of the local Verification
Record `.kogen/runtime/verification.json` and its history
`.kogen/runtime/verification-history.jsonl`, writing them after each cycle in
today's line format (candidate, status, target, exit_code, session_id,
attempt_token, finished_at) and archiving/resetting them only at each outer
attempt. After controller verification settles, controller code builds the
handoff report itself, so no handoff can be malformed or invalid; a declared
proof selector still missing from the Candidate is unfinished work, decided by
code, and uses one outer resumption. Jev (`jev-1.13.0`) reads the Developer's
free prose once per handoff; an objection at 0.85 confidence or higher stops
the Build immediately and returns it to Shaping, quoting the Developer's words
and Jev's confidence. Otherwise, a settled verification failure, a failed
declared target, or a Review finding uses one outer resumption of the same
Developer, when allowance remains, and a resumed attempt must settle a fresh
controller verification before the next handoff or Review. An exhausted
verification or outer allowance stops the Build rather than claiming success.

The Stop scripts (`.codex/hooks/check.sh`, `.codex/hooks/stop_runner.py`) are
bootstrap remnants, not a second verification authority: they act only on a
v1 unified `KOGEN_VERIFICATION_CONTEXT` supplied by an older controller (so an
in-flight Build can still finish automatically), and otherwise print
`{"continue":true}` and do nothing — no Make target, no verification record,
state, history or log. A follow-up Intent deletes them once every running
controller is the new one.

Developers and their delegated helpers must not run `make <goal>` for any
catalog target, or `.codex/hooks/check.sh`, including for early signal;
focused non-gate tests remain allowed. A tracked PreToolUse Bash guard blocks
`make <goal>` for every catalog target — not a hardcoded `check`/`live`
pair — and the Stop-script forms, before Bash dispatch. This guard is a
courtesy against running gates by hand, not a judge: the Build controller
runs `make -C <Candidate>` itself, outside every role's process tree, and
that run is what settles verification, whatever the guard does or a Candidate
edit to it changes. This bounded guard
deliberately does not inspect indirect execution through non-gate Make
dependencies, wrappers, shell expansion, `sh -c`, or later stdin; the Developer
contract still forbids those routes. Existing configurations using legacy
outer-resumption naming remain transition inputs; new documentation uses
`verification_retries` for controller verification and the outer allowance for
Developer rework.

Every scenario's `verified_by` is the complete, explicit list of catalog
targets that scenario needs — there is no implicit `check`, and no target name
is special. Admission no longer requires a `check` target; the plan loader
accepts a scenario's `verified_by` when it is a nonempty list of distinct
catalog targets, containing at least one `provider_backed: false` target and
at most one `provider_backed: true` target (which must equal
`proof.paid_target`), with every listed target's `dependencies` also listed,
in catalog rank order. The Build runs exactly the union of the approved
`verified_by` lists, in rank order, and never silently adds a target; receipts
form one uniform list, with no separate `check` field in the tracking record,
handoff report or review packet. Its required `proof` map names focused
offline selectors, optionally one causally justified narrow paid target, and
all affected implementation/assertion/fixture paths. Use
`offline-sufficient: ...` when no paid evidence is needed; provider-backed
proof must name the exact provider-only observation and why offline rehearsal
cannot establish it. The real lifecycle fixture has a bounded check target; it
never invokes the full live suite recursively.

An Intent's `intent.yaml` may declare `catalog_changes.add` to add new Make
targets and select them in the same Intent; a selected added provider-backed
target must list its rehearsal test as one of its file selectors. Each cycle,
the controller reads the Candidate's catalog and Makefile only as data — it
never loads Candidate code — and every selected target must exist in both;
removing, renaming or editing an *unselected* target needs no declaration and
appears in the verification-surface ledger below. The admission catalog can
also declare integrity fields consumed only by the controller:
`verification_surface` (`tests`/`runner` globs), `focused_runner` (an argv
template with `{paths}`), and `base_cache` (paths copied into a
controller-owned base workspace outside the repository; never
`.kogen/runtime`, `.kogen/build.lock`, `.kogen/codex` or `.codex/sessions`,
which the base workspace must never inherit). When those fields and a
scenario's `proof.base` (`fail` for new or changed behaviour, `pass` for
preservation) are present, the controller itself runs each scenario's file
selectors on the Candidate with the admission `focused_runner`; a `base: fail`
selector must also fail on the base workspace (base's own runner, only the
Candidate's selector and test-class files overlaid) before it is trusted, and
an exit of zero there fails verification as "proof cannot detect the change".
A `base: pass` selector that differs from base becomes a ledger item, and
base's bytes of it must still pass on the Candidate. A contract without
`proof.base` is labelled `unproven-on-base`; a catalog without the integrity
fields labels every scenario `integrity-not-configured`.

Before Review, the controller also computes a verification-surface ledger from
Git (Candidate against base) for every changed path matching
`verification_surface`, including paths outside every scenario's
`affected_paths`: status, full diff, and whether it is runner-class, plus a
report of base's test suite run against the Candidate's implementation (a
report, never a gate). The ledger and report go into the handoff report and
the review packet, never to Jev. The Reviewer must return exactly one
disposition per ledger item — `justified: <scenario-or-finding-id>` or
`weakening` — in a `ledger` verdict field, required only when the packet
carries a nonempty ledger; a `weakening` disposition opens a blocking finding
that returns to the same Developer as Review rework.

An opted-in isolated test can require forwarding of target evidence with
`target_evidence: :required`. A declared target may emit one
`KOGEN_TARGET_EVIDENCE_MANIFEST<TAB>{...}` line naming a repository-relative,
SHA-256-bound manifest. Build validates and snapshots that manifest and every
required artifact in the target receipt before Review. These controller-owned
snapshots preserve uncited required bytes; Reviewer citations remain separate
evidence of semantic inspection. Targets without a frame keep their existing
behavior.

Build validates the full Approved scenario contract before launching a provider.
Each scenario needs a unique nonblank `id`, `given`, `when`, `then`,
`wrong_result`, `evidence`, and a nonempty `verified_by` list of existing targets.
Optional `risks.yaml` entries have unique `id`, `scenario_ids`, and `description`;
file-ownership entries describe existing-path behavior, immediate and later owners,
permitted mutation, validation, Git state, and upgrades. An absent risk file is
recorded as “not supplied.” Shaping leaves unresolved ownership decisions to the
Shaper, including when a protected seed becomes user-owned configuration.

Role launches carry concise file and identity locators rather than task bodies.
Shaping starts from this README and maintained relevant context; Developer and
Reviewer read the complete selected Approved package and selected current fields
from the authoritative scenario-tracking record in their actual child working
directory. Rework names its failure category and record location while full
verdicts, findings, receipts, source snapshots, and historical exact bytes stay
in that record. Missing or conflicting required evidence is an integrity failure;
unfinished optional Draft files remain valid shaping work.

Before each Review the controller writes one immutable review packet per
attempt, `.kogen/runtime/scenario-tracking/<build-id>/review-packets/<attempt-number>.json`.
It is canonical JSON of at most 64 KiB (65,536 bytes), bound to the attempt
token and Candidate, holding the scenario and risk IDs, the controller handoff
report, the Developer notes, a summary of each receipt with a bounded output
tail, the open findings with their prior dispositions, any superseded
objection, and an `omitted` list. Long fields are cut at a UTF-8 boundary
(notes 16 KiB, handoff 24 KiB, each receipt output 2 KiB of its tail); every
cut or left-out item carries its full source SHA-256, byte count and a JSON
pointer into the record, and the required IDs are never dropped (Build stops
instead). The controller keeps the packet digest in its state and in the
attempt and verifies it before launch, after Review and during publication.
The Reviewer's `KOGEN_TASK_CONTEXT` names the packet as its evidence source;
`tracking_path` stays as an audit locator. The packet never narrows the
Reviewer's inspection of Candidate files or read-only commands.

After controller verification settles, controller code deterministically builds the
handoff report, bound to the fresh attempt token and the Candidate, from the
Approved contract, the Candidate's Git changes relative to HEAD, the declared
proof selectors, and Kogen's own receipts, so the report's format cannot fail.
The Developer's final message is free prose; Kogen code never parses it. Build
records it byte for byte as the Developer's notes and sends it, with the
controller-listed scenario, risk, and finding IDs, to TypeSafe Jev
(`jev-1.13.0`) once per handoff. Jev reports what the Developer says about
each item — unfinished, done, pending external verification, resolved or
historical, unclear — and whether the Developer objects that the approved
contract cannot be met. An objection at 0.85 confidence or higher stops the
Build immediately, without Review, and returns it to Shaping, quoting the
Developer's words and Jev's confidence. The one exception is a superseded
objection: when an earlier controller verification cycle of the same attempt (same attempt token
and Developer session) failed and the final cycle then passed on the settled
Candidate, the objection is recorded on the attempt as `superseded_objection`
(items, confidences, failed and passing cycle sequences) and reaches the fresh
Reviewer as a labelled advisory item in the review packet. Every other Jev reading, including a
confident "unfinished" answer, and any runtime Jev failure, reaches the
Reviewer only as a labelled advisory note; a confident "unfinished" answer
never routes rework by itself, and the Reviewer alone decides acceptance or
rework. A fresh Reviewer assesses every scenario and explicitly closes or
retains every open finding with inspected counterevidence or repair evidence.
Acceptance requires all scenarios satisfied and no open blocking findings for
the current Candidate. A declared proof selector still missing from the
Candidate is unfinished work decided by code; it uses one outer resumption of
the same Developer, and the next attempt needs a fresh controller verification.
Verification exhaustion and a Jev cannot-comply stop both take precedence
over ordinary Review routing, and outer-allowance exhaustion takes precedence
over another launch. Malformed Review still stops without partial closures.

To inspect a stopped Build, start with the record path and unresolved scenario IDs
in its error. Read `.kogen/runtime/scenario-tracking/<build-id>/record.json`:
`scenarios` and `risks` preserve requirements, `attempts` separate claims, receipts,
and verdicts, and `findings` retain stable IDs, origins, and dispositions. Each
Build gets a new versioned record even with raw logging disabled. Records are
inspection evidence, not restart checkpoints; review the worktree and Approved
package before any new Build. Do not edit these controller-owned records.
Citations retain separate Developer and Reviewer versions of the exact inspected
bytes in each attempt's `developer_reference_snapshots` and
`reviewer_reference_snapshots`; a later citation cannot replace an earlier role's
version. Ordinary cited files keep an inline `content_base64` snapshot. A
citation of the Build's own record never copies the record into itself: it is
kept as metadata (path, SHA-256, byte count, `controller_record_version`
binding) plus an immutable, exclusively created sidecar
`.kogen/runtime/scenario-tracking/<build-id>/record-versions/<sha256>.json`
holding the exact cited bytes. Build, publication and
`Kogen.Build.Evidence.resolve/2` verify every referenced sidecar; a deleted or
edited sidecar stops Build. Older records with inline record snapshots stay
readable. Subsequent controller updates
are checked against Build's latest owned bytes. External edits still stop Build.
Successful publication links concise Complete evidence to the bound local full
record; generated names never replace supplied evidence. Failed publication
restores the frozen Approved input.
Build refuses Git assume-unchanged and skip-worktree flags wherever it relies on
Candidate identity, including controller verification and publication, without clearing those flags.

New Complete packages commit a versioned `build-summary*.json`, not the full
scenario-tracking record. The exact record remains in its ignored
`.kogen/runtime/scenario-tracking/<build-id>/record.json`; `evidence.md` explains
how to resolve it from the checkout root and verify its SHA-256 and byte count.
A clone retains the contract and concise result, but not those exact local bytes.
If the archive has been cleaned up, report it unavailable—do not substitute a
summary or another Build's record.

Immediately before commit, Build measures every added or modified staged
destination relative to the starting `HEAD` by its full uncompressed Git blob
length. The fixed limit is 5 MiB (5,242,880 bytes) per path and 10 MiB
(10,485,760 bytes) in aggregate; equality is allowed, deletions and unchanged
historical blobs cost zero, and there is no override. Added or modified staged
paths under `.kogen/runtime/` are always rejected, including force-staged ignored
files. An Approved package already unable to meet these limits stops before a
provider launch and must return to Shaping.


## Configuration and local data

Edit the tracked `.kogen/config.yaml` to define named **routes** and a
`default_route`. A clean route pairs one `harness` (`claude` or `codex`) with the
model and effort for `shaping`, `developer`, `reviewer` and each required
helper profile (`helpers.scout`, `helpers.worker`, `helpers.expert`);
`outer_resumptions` and `verification_retries` stay top-level, shared by every
route:

```yaml
default_route: claude
routes:
  claude:
    harness: claude
    shaping:   {model: claude-opus-5-5, effort: medium}
    developer: {model: claude-opus-5-5, effort: medium}
    reviewer:  {model: claude-opus-5-5, effort: medium}
    helpers:
      scout:  {model: claude-sonnet-5, effort: low}
      worker: {model: claude-sonnet-5, effort: medium}
      expert: {model: claude-opus-5-5, effort: high}
  codex:
    harness: codex
    shaping:   {model: gpt-6-sol, effort: medium}
    developer: {model: gpt-6-sol, effort: medium}
    reviewer:  {model: gpt-6-sol, effort: high}
    helpers:
      scout:  {model: gpt-6-luna, effort: low}
      worker: {model: gpt-6-luna, effort: high}
      expert: {model: gpt-6-sol, effort: high}
  claude-dominant-adversarial-codex:
    shaping:   {harness: claude, model: claude-opus-5-5, effort: medium}
    developer: {harness: claude, model: claude-opus-5-5, effort: medium}
    reviewer:  {harness: codex, model: gpt-6-sol, effort: high}
    expert:    {harness: codex, model: gpt-6-sol, effort: high}
    helpers:
      claude:
        scout:  {model: claude-sonnet-5, effort: low}
        worker: {model: claude-sonnet-5, effort: medium}
      codex:
        scout:  {model: gpt-6-luna, effort: low}
        worker: {model: gpt-6-luna, effort: high}
  # codex-dominant-adversarial-claude is the mirror image: Codex shapes and
  # develops, Claude Code reviews and answers Expert questions.
outer_resumptions: 2
verification_retries: 2
```

A hybrid (role-level) route has no top-level `harness`: each of `shaping`,
`developer`, `reviewer` and `expert` names its own `harness`,
`model` and `effort`, and `helpers` holds the native `scout` and `worker`
profiles of every harness a role uses. A missing role assignment or helper set
is refused with its key path; nothing falls back to the dominant harness. A
clean route needs no new keys: its Expert is `helpers.expert` on its one
harness; a role-level `harness` inside a clean route is refused. Helpers are always native to the
harness of the role that launches them. The Expert is a role: a role on the
Expert's harness delegates to it as its native expert helper, and a role on
another harness (in `claude-dominant-adversarial-codex`, Shaping and the
Developer) consults it only through `mix kogen.expert`, which launches one
fresh read-only Expert on its assigned harness, model and effort from the
frozen `KOGEN_EXPERT` assignment the role's launch carries, reads its question
on stdin and prints its answer. It never reads `.kogen/config.yaml`, and no
native helper is ever substituted for it.

This repository's own `.kogen/config.yaml` defines these four routes: the clean
`claude` and `codex` routes and both hybrids. A `--route
<name>` flag on `mix kogen.shape` or `mix kogen.build` selects the route for
that session; without it, the session uses `default_route`. An unknown route
name fails before any harness open or provider launch, naming the unknown
route and listing the available route names in sorted order. Only the
selected route's harnesses and models are validated for support and readiness;
another route may name an unsupported or unready harness without blocking a
session on a different route. Shape checks the readiness of the Shaping
and Expert harnesses, and Build of the Developer, Reviewer and Expert harnesses,
before any role launches; a harness that is not installed, logged in or
supported fails naming its roles and harness, and selections already held are
released. A config still using the old flat shape
(top-level `harness:` and roles, no `routes`) is refused before launch, with a
message naming `default_route` and `routes` as the replacement — there is no
compatibility reader or migration.

Kogen passes each root profile directly to the selected route's harness and
renders the helper profiles into every role prompt; it does not silently
inherit or substitute a missing or unavailable profile. All three helper
profiles are required on every route, though a role delegates only when
bounded independent work justifies the startup and integration cost.

Shaping records the selected route in the Draft (`shaping.route`, alongside
`harness`/`model`/`effort`/`started`), and each continuation records the
route used for that visit; the Draft's original `shaping` block is never
rewritten, and Drafts saved before routes existed remain continuable. A Build
resolves its route once and freezes it — name, harness and every resolved
role/helper profile under `route`, and the complete role matrix (every
role's harness/model/effort, including the Expert, and each
harness's native helper profiles) under the additive `role_assignment` — in
its scenario-tracking record, and takes every launch profile from that frozen
matrix; later edits to
`.kogen/config.yaml`, including changing `default_route`, do not affect a
Build already in progress. The Developer is resumed on its own harness and
session, controller verification stays with the Developer, and each Review is a fresh
session on the Reviewer's harness with the same review packet. The committed
`build-summary.json` names the Build's route and harness and carries the same
`role_assignment`; `evidence.md` names every role's harness.

[Shared execution guidance](priv/kogen/prompts/execution-policy.md) has one
[renderer](lib/kogen/execution_policy.ex), expanded by fresh/continued Shape
and the Developer/Reviewer launch routes. Role templates retain approval, gate,
Candidate and output authority. Maintain profile values in config and shared
guidance in that source; update public-route regressions when changing either.
The [live native-helper fixture](test/kogen/native_helper_live_test.exs) checks
transport and deterministic facts, not model quality or savings; historical
measurements remain workload-specific. Its
[receipt controls](test/kogen/native_helper_fixture_test.exs) reject missing or
contradictory native evidence. The existing live lifecycle also audits actual
[root session profiles](test/support/root_profile_audit.ex). Regenerate evidence
through the Build-owned provider-backed targets using the prerequisites below; inspect the
new run’s retained receipts and raw snapshots on failure, without substituting
a prior passing run.

The connected Shape-to-Commit and Build-only Reviewer-rework live cases are
separate async modules, allowing their private ordered lifecycle chains to
overlap when scheduler capacity permits. Both audit their own current native
streams; the former three-call primitive probe is consolidated into those
owners and offline corruption controls. Semantic Review, native-helper, and
cold-offline proof remain separate cases.

Shaping quality is also exercised by a maintained
[five-case evaluation](test/support/shaping_evaluation/README.md): flawed and complete
CSV/availability pairs plus a frozen-seed continuation run as isolated concurrent
public Shape sessions. Its offline rehearsal covers the real orchestration and
consumer route; the live owner emits one required-artifact manifest, while ordinary
independent Review assesses the retained conversation and Draft semantics. Target
selection follows the offline-first policy in
[Choosing verification targets](#choosing-verification-targets), not whether a
live test file changed.

### Verification target selection

No target name is special to the controller; `verified_by` is the complete,
explicit list a scenario needs. Kogen's own catalog keeps `check`, the
complete provider-denied offline gate, and every scenario in this repository
still selects it because offline sufficiency covers almost everything here —
not because admission requires it. Select additional targets by affected
behavior and preservation risk, not by edited filenames, following the
offline-first policy in [Choosing verification targets](#choosing-verification-targets):

| Target | Select when | Classification and prerequisites |
| --- | --- | --- |
| `check` | Offline sufficiency covers the behavior and failure controls; a later Intent may use check only. | Offline; installed dependencies and the tools below. Provider dispatch is denied. |
| `live-shape-to-build`, `live-reviewer-rework`, `live-general` | The corresponding configured-default lifecycle or Review workflow (on `default_route`) can change. | Provider-backed on `default_route`'s harness; network, its installed runtime and Kogen login, `expect`, and `rsync`. |
| `live-shaping-quality` | Shaping prompts, continuation, Draft quality, evaluation cases, prerequisites, or its evidence manifest can change. | Provider-backed; network, configured Codex authentication, and maintained evaluation sources. |
| `live-native` | The authenticated native boundary, managed runtime/login/discovery, compatibility runner, helper routing, profiles, or native receipts can change. | Provider-backed; installed pinned Codex runtime and configured authentication. |
| `cold-offline` | Cold-cache behavior, the offline recipe, dependency copying, toolchain setup, containment, or cold cleanup can change. | Offline, though expensive; installed dependency sources, `rsync`, and the offline toolchain. Provider dispatch is denied. |

Use check only when deterministic offline evidence is sufficient. Select one
narrow paid target per scenario only when its proof names a provider-only
observation that offline rehearsal cannot establish. The controller deduplicates
and orders selected targets by catalog dependency and cost rank, not scenario
order, and there is no aggregate target. Multiple scenarios may collectively
select multiple boundaries. Offline rehearsal proves recipes and evidence
consumers, not real provider access. For multiple affected boundaries, select
each relevant target through its own scenario proof and causal reason.

Build validates every selected target against the catalog and Makefile before
Developer launch. The controller preserves Candidate/session/attempt binding,
verification retries, required artifacts, receipts, and the fresh-Review boundary.

Kogen loads the tracked project hooks and launches the selected route's harness with approval, sandbox, and hook-trust prompts bypassed so the Build can run autonomously: Codex CLI with its bypass flags, Claude Code with `--dangerously-skip-permissions` (no permission prompts and no sandbox) for every role, including interactive Shaping and login.

Drafts, Approved Intents, Build locks, and raw runtime logs are local and ignored by Git. Complete Intents and concise verification evidence accompany successful commits. `KOGEN_HARNESS` remains an offline test override; ordinary work selects Kogen's pinned managed runtime, never a `claude` or `codex` from PATH.

## Choosing verification targets

Kogen's own orchestration — the controller, the verification plan, receipts,
scenario tracking, reports, Jev plumbing, guards and catalog rules — is
offline-only: none of it needs a real provider to prove. Prompt wording is
also offline-only, unless a scenario claims a model-behaviour outcome (that a
real Developer or Reviewer session actually does something on a real harness).

A paid, provider-backed target is reserved for:

- native harness launch, resume or flags;
- native hook registration consumed by a real CLI;
- managed runtime upgrades; and
- parsing new provider output shapes.

An existing live test exercising the changed path is not, by itself, a reason
to select a paid target — deterministic orchestration is proved offline,
including through a complete fake-harness run. But an Intent that edits a live
test's owner file must select that test's target in the same Intent: an edited
live test that never runs is unverified. Otherwise, an Intent selects at most
one paid target, unless the Shaper explicitly accepts more, with the reason
recorded in `questions.md`.

## Self-hosting changes: expand and contract

Kogen builds itself. A Build runs main's controller — the code loaded when
`mix kogen.build` started — against a Candidate that may be changing the same
machinery the running controller depends on. Removals therefore follow expand
and contract, like a zero-downtime database migration: one Intent adds the new
path, switches the new controller to it, and keeps the old path working for
the running controller; the next Intent, built under the new controller,
removes the old path.

As of this commit, here is what the running controller reads or runs from the
Candidate during a Build:

- the catalog and its change rules: `priv/kogen/verification_targets.yaml`,
  `lib/kogen/build/verification_plan.ex` (`VerificationPlan.load/1`),
  `lib/kogen/build/catalog_change.ex` (`CatalogChange.check/4`)
- the Make target definitions: `Makefile`, run by
  `lib/kogen/build/verification_runner.ex` (`VerificationRunner.run_target/4`)
- the admission catalog's integrity fields: `verification_surface`,
  `focused_runner` and `base_cache` in `priv/kogen/verification_targets.yaml`,
  consumed by `lib/kogen/build/base_workspace.ex` and `lib/kogen/build/ledger.ex`
- the files and registrations `VerificationPolicy.preflight` requires:
  `lib/kogen/verification_policy.ex` (`.codex/hooks/verification_policy.py`
  and the PreToolUse registration in `.codex/hooks.json`)
- the Stop scripts and registrations (bootstrap only): `.codex/hooks/check.sh`,
  `.codex/hooks/stop_runner.py`, `.codex/hooks.json`,
  `priv/kogen/claude_code/settings.json`
- the guarded-path check: `lib/kogen/build/guarded_paths.ex`
  (`GuardedPaths.check/2`)
- the approved package: `.kogen/intents/approved/<slug>/`, read by
  `lib/kogen/build.ex` and `lib/kogen/build/contract.ex`

The running controller also renders the Candidate's role prompts,
`priv/kogen/prompts/developer.md` and `priv/kogen/prompts/reviewer.md`, at
every launch, and reads `priv/kogen/test-reliability.yaml`.

**Worked example.** Intent `fortify-paid-verification` keeps the Stop scripts
so this Build, started under the old controller, can still finish
automatically; the next (follow-up verification) Intent, built under the new
controller, removes them. The `live-native` split is done next too, through
that follow-up's declared `catalog_changes.add`, because this Build cannot
change the catalog it was admitted under.

Shaping should check each Intent that touches these inputs, and split it into
two when one Build cannot both change the input and still settle, review and
commit.

## Choosing a route

Each route's harnesses in `.kogen/config.yaml` are `claude` or `codex`; any
other name is rejected with that list, but only for the route a session
selects — an unselected route may name an unsupported harness without
blocking other routes. Build, Shape and provider-outcome handling call one
harness interface; the selected route's adapter supplies install and login
readiness, launch context, fresh and exactly resumed Developer turns, Reviewer
verdicts and the interactive Shaper. Controller-owned verification and the
local Verification Record are shared and harness-independent; the Stop scripts
are inactive bootstrap remnants under this controller (see "The loop" above).
Both adapters' offline suites run in every `make check`.

Switching provider means either passing `--route <name>` for one session or
changing `default_route` for future ones, after that route's harness install
and login. The general provider-backed lifecycle targets (`live-general`,
`live-reviewer-rework`, `live-shape-to-build`) run on `default_route`, while
the Codex-only `live-native` owners always resolve the one route whose harness
is `codex` (and fail, listing the candidates, when there is none or several).
Re-proving a harness therefore means running those general targets with
`default_route` naming a route on that harness (plus `live-native` for Codex)
before relying on it; another route's earlier paid evidence does not carry
over. Codex remains a supported adapter; its documentation below still
applies when a route names `harness: codex`. Harness setup commands
(`mix kogen.{claude,codex}.{install,login,status}`) never select, require or
validate a route — they operate on their own harness regardless of which
route is `default_route`.

## Managed Claude Code runtime and login

`mix kogen.claude.install` installs the exact Claude Code release pinned by this
checkout (2.1.281) from the official npm registry into Kogen's managed root,
checking the pinned per-platform sha512 integrity, staging privately and
publishing atomically. It never resolves latest, never uses a `claude` on PATH,
and never writes to personal Claude Code locations such as `~/.local/share/claude`.
Repeating it reuses an intact installation; a failed download, integrity check or
extraction preserves any working runtime and every login. Every Kogen launch sets
`DISABLE_AUTOUPDATER=1`, so the managed runtime never updates itself. Kogen's
roles run unattended, so every launch also sets
`CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT=1`, overriding any inherited value;
without it Claude Code asks to confirm a recursive `rm` whose target is
command-substitution output, even with `--dangerously-skip-permissions`. Pin changes
follow the [Claude Code runtime upgrade workflow](workflows/claude-code-runtime-upgrade.md).

Kogen's Claude Code login is separate from personal Claude Code, so Kogen can use a
different account or subscription. `mix kogen.claude.login` opens the managed
interactive `claude` in Kogen's shared scope; complete Claude Code's own first-run
flow there, choosing either a Claude subscription or Anthropic Console (API
billing) login, then exit. `--project` does the same in this project's private
scope, selected first so cancellation never falls back to the shared login;
`--use-default` switches the project back to the shared scope and keeps retained
project logins. Arguments after `--` are forwarded unchanged to `claude`:

```sh
mix kogen.claude.login
mix kogen.claude.login --project
mix kogen.claude.login --use-default
mix kogen.claude.login -- --help
```

`mix kogen.claude.status` reports the pin, installation, effective scope and the
`loggedIn` and `authMethod` metadata of `claude auth status`, never credential
values or remaining quota. Fresh and continued Shaping and Build stop before any
model launch and name the fix when the pinned runtime, the selected login, or a
proven model is missing.

Runtimes, scopes and selectors live under `~/Library/Application Support/Kogen/claude`.
Each scope (`accounts/shared`, `accounts/projects/<project-id>`) is a private
`CLAUDE_CONFIG_DIR` holding Claude Code's own config and sessions. Claude Code keeps
each scope's login in the macOS Keychain keyed by the scope path, so never move or
rename a scope directory: that loses its login. Kogen never reads, copies or prints
credentials and never touches personal `~/.claude`. Role launches load only project
settings plus Kogen's hook settings (`--setting-sources project`), no MCP servers or
cached account connectors (`--strict-mcp-config`), and remove inherited provider
variables such as `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, base URLs and
Bedrock/Vertex switches.

Each Build gets its own harness home,
`<workspaces-root>/<project-id>/harness/<build-id>/` (see the Build paragraph
above), and every Claude Code role of that Build launches with
`CLAUDE_CONFIG_DIR=<harness home>/claude`. The login itself is never copied
there: `CLAUDE_SECURESTORAGE_CONFIG_DIR` is set to the resolved login scope
path (the shared or project scope, resolved once from control at admission,
never the Candidate), and `HOME` stays the user's real home. A private `HOME`
for Claude Code loses the Keychain login even with the right scope, which is
why Kogen never sets one for it. Every Kogen Claude Code launch — every Build
role, Shape, `mix kogen.claude.login` and `mix kogen.claude.status` — removes
an inherited `CLAUDE_SECURESTORAGE_CONFIG_DIR` before setting its own: an
empty inherited value would silently authenticate with the personal Claude
Code login instead of Kogen's scope. Claude launches also remove the Codex
adapter's credential prefixes (`CODEX_`, `OPENAI_`, `AZURE_`, `CHATGPT_`),
mirroring Codex's removal of `ANTHROPIC_`. A scope-native launch (Shape,
login, status) sets `CLAUDE_SECURESTORAGE_CONFIG_DIR` equal to
`CLAUDE_CONFIG_DIR`, selecting the same Keychain item as today. Codex roles
keep `CODEX_HOME` as the scope itself, because Codex has no separate
auth-home variable, and get their own operation root (private `HOME`,
`XDG_*` and sqlite) under `<harness home>/codex`. Every binding is resolved
once at admission, from the control checkout, and written to the Candidate's
owner record before any readiness check or other harness process starts;
readiness then checks those recorded bindings, and the whole Build uses
them. Changing the login selector while a Build runs does not affect it.

Interactive Claude Code asks once per new repository whether to trust it (the
default answer exits), even in bypass mode. Answer it for your own repositories;
Kogen never answers it.

### Proven Claude Code models

Configured Claude Code models must appear in the model picker
[`priv/kogen/claude_code/models.yaml`](priv/kogen/claude_code/models.yaml), which
lists only models with retained evidence: `claude-opus-5-5` and `claude-sonnet-5`,
each at efforts low, medium, high and xhigh. Haiku 4.5 is excluded because it does
not support the per-role effort Kogen configures. Kogen launches the exact
configured model and effort, never a fallback model, and does not intercept
provider requests. It records the model each response came from, including
helper responses linked to their parent, and fails a turn whose root response came
from another model. Opus 5.5 for every root role consumes a subscription quickly;
limits surface as provider errors, never as model substitution.

Each role gets its own Claude Code agents, `kogen-scout`, `kogen-worker` and
`kogen-expert` (the last only when the route assigns the Expert to Claude Code),
carrying the route's Claude Code helper profiles but only that role's authority:
Developer scouts are read-only, workers may edit their assigned paths, and experts
are read-only with Bash; every Reviewer and Shaper helper is read-only. Built-in
Claude Code agents are denied to every role. The Developer's final message carries
no schema; Kogen never validates or parses it, and controller code builds the
handoff report on its own. The Reviewer still returns its verdict through
`--json-schema`.

## Managed Codex runtime and login

`mix kogen.codex.install` installs and validates the exact official native runtime pinned by this Kogen checkout. Repeating it verifies and reuses an intact installation. Failed staging preserves existing runtimes, accounts, and sessions.

`mix kogen.codex.login` delegates browser login to native Codex in the shared Kogen scope. Kogen scope options precede `--`; native arguments follow it unchanged:

```sh
mix kogen.codex.login -- --device-auth
mix kogen.codex.login --project -- --device-auth
printenv OPENAI_API_KEY | mix kogen.codex.login -- --with-api-key
printenv OPENAI_API_KEY | mix kogen.codex.login --project -- --with-api-key
mix kogen.codex.login -- --help
```

Device authorization still requires a human. `--project` selects a private project scope before login, so cancellation never falls back to shared credentials. `mix kogen.codex.login --use-default` explicitly reselects shared login without authenticating or deleting retained project credentials. Native Codex owns credential formats and refresh; Kogen never imports personal credentials.

`mix kogen.codex.status` reports the checkout pin, installation and actual active-use records, effective scope, and native local login state. It does not install, authenticate, call a model, expose secrets, or claim remote entitlement. Fresh/continued Shaping and Build stop before provider work when the pinned runtime or selected login is missing.

Managed distributions, accounts, selectors, settings generations, sessions, and compatibility evidence live under `~/Library/Application Support/Kogen/codex`. Per-launch discovery homes exclude personal Codex settings while project guidance and tracked hooks remain available. Shell tools and hooks retain the caller's HOME and exact set/unset XDG semantics. Every managed Codex role and native helper launch carries one central `-c tool_output_token_limit=4000`, about Claude Code's Bash result cap, so a large tool result is not re-sent in full on every later step. Active operations retain their concrete runtime and session across Review and exact resume; new checkouts select their own pin.

The `live-native` compatibility runner drives discovery, interactive Shaping, the Developer with its controller verification, and the exact Developer resume with its scout helper. The resume is driven by a fixed rework request held in the runner. The real Reviewer is proved by `live-reviewer-rework`, not by a scripted stand-in. The runner owns its own timing: it passes each native turn the unchanged 240 s limit explicitly, and the whole test must finish within 15 minutes. A `timed_out` attempt is rerun once in a fresh fixture, and only if a typical run still fits before that deadline. No other failure is retried. Both attempts' class, provider session ids, elapsed time and cleanup are kept in one repository-relative summary under `.kogen/runtime/codex-compatibility/`, which the test emits as its target evidence manifest.

When upgrading Kogen's pinned Codex runtime, follow the [Codex runtime upgrade workflow](workflows/codex-runtime-upgrade.md).

## Role write boundary

On macOS, every role process tree of a Build — the Developer, every resume,
the Reviewer, their native helpers, hooks (including Stop and any `make` it
or the Developer starts), `mix kogen.expert` and the Expert it launches, and
anything any of them spawns — runs inside one macOS Seatbelt profile, applied
by the kernel at launch (`/usr/bin/sandbox-exec -p <profile>`). Descendants
inherit the profile and cannot remove it. Writes are allowed only under: the
Candidate; the Build's harness home; a spaceless per-Build temp dir (set as
`TMPDIR`, `TMPPREFIX` and `CLAUDE_CODE_TMPDIR`); the stdio and pty devices;
and shared login state the login needs to keep working — the login keychain
file and its `.sb-` temp files, the Claude scope's `.oauth_refresh.lock` when
the route uses Claude Code, and the Codex scope minus the entries Kogen owns
or refuses (`hooks.json`, `plugins/`, `rules/`, `config.d/`, `AGENTS.md`,
`AGENTS.override.md`, `environments.toml`, `agents/`, `.kogen-owned`) when the
route uses Codex. Role launches get `KOGEN_RAW_LOG_DIR=<harness home>/raw-log`,
copied into the controller's own `KOGEN_RAW_LOG_DIR` at Build exit; the
controller's own log directory is not itself granted. `/bin/ps` is the one
executable run outside the profile, because sandboxed processes cannot exec
setuid binaries; LaunchServices opens and Apple Events are denied.

Everything else fails closed with `EPERM` ("Operation not permitted"),
including writes through symlinks, hardlinks, renames and `/tmp` aliases: the
control checkout (its Git metadata lives there too, so a role's `git add`,
`commit`, `stash` or similar fail — the controller stages and commits),
other Candidates, other harness homes, owner records, the Claude scope
directory itself, and the user's home. Reads, network access and process
execution stay open, and `git status`/`git diff` still work in the Candidate.

Kogen keeps `--dangerously-skip-permissions` for Claude Code and
`--dangerously-bypass-approvals-and-sandbox`/`--dangerously-bypass-hook-trust`
for Codex: the enclosing kernel profile is the actual enforcement and already
covers what those harness layers would, including the harness's own writes
(the Write tool, `apply_patch`, session files), and Codex's own Seatbelt
cannot nest inside another profile. The tracking record's `boundary` block
records `applied` or `inherited` — `inherited` only for a fixture Build with
`KOGEN_HARNESS` test roles started inside another Build's role boundary; a
Build with managed-runtime roles refuses to start confined at all ("a Build
cannot start inside another Build's role boundary"). Confinement is decided
by the kernel's own self-test, never by an environment variable. Every grant
is resolved to its canonical, symlink-resolved path first; if
`/usr/bin/sandbox-exec` is missing, a grant cannot be resolved or is
forbidden (`/`, `/private/tmp`, `/private/var`, `$HOME`, the control root or
an ancestor of it), or the admission self-test fails, the Build stops before
any launch — there is no unwrapped fallback. After a macOS upgrade, re-run
the boundary probes (`evidence/write-boundary-probe-2026-09-25.md` under this
Intent's evidence) before relying on the mechanism again; kernel denials show
up with `log show --predicate 'eventMessage CONTAINS "deny(1) file-write"'`.

The write boundary is macOS only. The parent controller and its verification
children (`make check` and the selected targets) run unconfined, because the
controller must write the record, the lock and receipts, and a fixture Build
started inside `check` or a live target has to apply its own profile; Shaping
sessions are outside it too (their containment is a separate, later piece of
work).

**Limits.** The controller still runs from control's own compiled code and
`priv/` at every Build, so editing Kogen's own engine files in control during
a Build can affect that Build (pinned generations are future work). Codex
keeps its rollouts, login refresh and bookkeeping inside its granted scope, so
that scope, and the shared login keychain item, stay writable by roles for as
long as logins need them to. Reads are never confined by this boundary.

## Run the checks

```sh
make check                 # Complete provider-denied offline gate
make live-shape-to-build  # Connected Shape-to-Build lifecycle acceptance
make live-reviewer-rework # Build-only Reviewer rework acceptance
make live-general         # Independent semantic Reviewer acceptance
make live-shaping-quality # Provider-backed maintained Shaping evaluation
make live-native          # Provider-backed native/runtime/helper compatibility
make cold-offline          # Offline gate from an empty private build cache
```

Fetch dependencies first. Python 3.11 or newer, `rsync`, and the macOS Command Line Tools (`xcrun clang`)
are also required for the offline gate and bounded subprocess probes.
`make check` runs formatting, forced warnings-as-errors compilation,
strict Credo, Boundary enforcement (including its compiler negative control), ordinary
tests, and the complete fake lifecycle without provider requests. No dependency
fetching or cached test results are used. The recipe reports each stage and the
whole gate's elapsed time, including failures; roughly ten seconds is a warm-cache
guideline, with no elapsed-time failure cutoff.

All test modules run asynchronously. Cases that mutate cwd or environment execute
in private OS processes using the current compiled application and dependency code;
fixtures, temporary roots, and writable build caches stay private. The fake public
Shape/Build fixture uses a small real check through the controller, including
failed verification correction and independent Reviewer rework. It never nests this suite.
Readiness-aware process probes give startup and post-readiness behavior separate
monotonic bounds, reject stale markers, and settle owned descendants before cleanup.
Dependency fixtures reject destination collisions and materialize linked sources
instead of retaining writable aliases to installed dependencies.
See [the check workflow](scripts/check/README.md) for maintenance and timing conditions.

The provider-backed lifecycle targets are narrow owner routes, not a complete suite. They
run on `default_route`'s harness only and require network access, its installed runtime
and Kogen login, `expect`, and `rsync`; create disposable
fixtures; and retains evidence under `.kogen/runtime/`. It covers real failed-check
correction, exact Developer resume, reviewer-directed rework, and fresh independent
Review. The Build-only Reviewer-rework fixture creates its project in a
canonical (symlink-resolved) directory under the system temporary directory,
outside the checkout, asserts that before the nested Build together with a
logged-in Kogen Claude Code scope, and retains its records, sidecars, review
packets, Complete package and a review-packet audit summary (including
per-Review elapsed seconds) in the owned log directory. Separately selected `make cold-offline` owns the empty-cache offline run. Set
`KOGEN_LIVE_LOG_DIR` to retain lifecycle or cold evidence elsewhere.

## Project and contact

Kogen continues work that began as Optimum Codegen. The retained history predates this core; commit `3f5af338` marks the **Start from clean slate** boundary. Earlier implementation instructions are historical; the fuller design remains a revisable direction for future features.

Read the [Origins](https://kogen.dev/origins/) for the story behind Kogen.

Questions and inquiries: [contact@kogen.dev](mailto:contact@kogen.dev).

Copyright 2026 Optimum Tech, LLC. Licensed under [Apache 2.0](LICENSE).

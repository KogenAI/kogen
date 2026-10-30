# 03 Approval and starting a Build

The caller reviews the shaped Intent and approves its exact bytes. A Build starts only when the caller asks for it with `kogen intent build <slug>`. There is no queue, background run or automatic restart.

**AUT-1 — Review card.** `kogen intent approve <slug>` without a hash reuses complete successful readiness evidence for the same full protected baseline hash, HEAD and Snapshot candidate tree, or runs the readiness checks (SHP-8), and prints the card (exit 5, the caller decides):

```
Intent: is-even — Add an is-even helper
SHA-256: {sha256}
Approver: {ident}

Acceptance
  - Even numbers (fails now)
  - Odd numbers (fails now)
  - Non-integers (fails now)

Readiness observations
Checked baseline: {sha256}
HEAD: {checked-head}
Acceptance exit: 1
Evidence: .kogen/local/readiness/is-even.json
{bounded actual failed-scenario details}

Files
  - .kogen/intents/is-even/intent.md
  - .kogen/intents/is-even/acceptance.feature
  - features/steps/is_even_steps.js
  - .kogen/project.yaml
  - .style.cfg
Approve with:
  kogen intent approve is-even {sha256}
```

Each Scenario Outline appears once as `<outline name> (<n> examples) (<status>)`, where `<n>` is the number of its Examples rows and the status is `fails now` if any row fails or `passes now` if every row passes. Each ordinary Scenario appears once with its existing status.

`Approver` is `--by` when given, otherwise `git var GIT_AUTHOR_IDENT`; with neither: `intent/approval_identity_unavailable: no Git identity names the approver; run git config user.name "<name>" and git config user.email "<email>" (global or repository), or run kogen intent approve <slug> <sha> --by <name>` (exit 2). A not-ready Intent prints `intent/not_ready` (SHP-8, exit 1) and no card. An unknown slug is `intent/not_found: Intent does not exist` (exit 2). Pending questions: `intent/questions_pending: <slug> has <n> unanswered question(s); answer them with kogen intent shape <slug> <file|->` (exit 5).

The card exposes the same checked readiness observations as the shaping/refinement conversation: actual failed scenario/step or hook/location, bounded error, acceptance exit, full baseline/hash/HEAD and evidence reference. Cached unchanged cards reuse those observations without execution; explicit truncation markers disclose omitted lines/bytes. Missing observation metadata in a legacy record is a normal cache miss. These observations do not classify every fixture as sound or require baseline green.

**AUT-2 — Hash and approval.** The hash is the SHA-256 over the acceptance baseline (VER-1): for each file, sorted by path, `<path>\0<sha256 of its bytes>\n`. `kogen intent approve <slug> <hash>` takes 6–64 lowercase hex characters (else a usage error). A prefix that does not match prints `intent/hash_mismatch: <slug> is now <sha256>, not <prefix>; review it again with kogen intent approve <slug>` (exit 1). Successful stable shaping, published refinement or a fresh review card records complete readiness evidence under `.kogen/local/readiness/`, keyed by the full baseline hash, declarations, `HEAD` and Snapshot candidate tree. A matching hash approval skips readiness only when that complete successful record matches the current baseline hash, declarations, `HEAD` and Snapshot candidate tree; when any differs, approval runs readiness again. A prefix that no longer matches the baseline is refused before readiness. A match writes `.kogen/local/approvals/<slug>.json` (`slug`, `sha256`, `approver`, `approved_at`) and prints `approved <slug> <sha8>` and `Next: kogen intent build <slug>` (exit 0). Approval shares the project lock with refinement and Build. Refinement of a matching approved package archives and revokes the old approval only on success (SHP-11); every refined package requires this fresh explicit approval. Approval never starts a Build; the shaping model can never create one. Evidence: the AUT-2 scenarios and the SHP-7 scenario.

**AUT-3 — Building one Intent.** `kogen intent build <slug>` builds that Intent if its approval is current. Unknown slug: `intent/not_found` (exit 2). Not approved: `intent/not_approved: <slug> is not approved; review it with kogen intent approve <slug>` (exit 5). Changed after approval: `intent/changed_since_approval: <slug> changed after approval and is now <sha8>; review it again with kogen intent approve <slug>` (exit 1). A landed Intent is not approved any more (AUT-6). Model: `shaping.qnt` `BuildOnlyOnCurrentApproval`, `LandedHasNoApproval`.

**AUT-4 — One Build per repository.** A Build holds an exclusive operating-system lock on `.kogen/local/build.lock` for as long as it runs; the file also records its pid. While that lock is held, another `kogen intent build` prints `environment/build_running: a Build is running in this repository (pid <pid>)` (exit 3). The operating system releases the lock whenever the Build ends, even when kogen is killed, so the next Build simply takes it, without a notice. A lock file left by an earlier Kogen (a pid file or a lock directory) counts as held while its pid runs; otherwise Kogen deletes it, writes `kogen: removed the lock of a Build that is no longer running` to stderr and takes the lock. Evidence: the AUT-4 scenarios (a live lock refuses; an earlier Kogen's dead lock is removed; a killed Build's lock is taken without a notice). Model: `run_control.qnt` `RunningBuildRefusesSecond`.

**AUT-5 — Start checks.** Optional fresh Build `--context <file>` is validated first, before provider requests or implementation/index/HEAD/approval effects: a readable regular file, valid nonblank UTF-8, at most 262144 original bytes. File errors are concise `intent/context_unavailable` usage errors (exit 2). Omission leaves the ordinary path unchanged. Before any model request, in this order, the Build refuses on: an invalid configuration (SET-4); no HEAD (`environment/no_head: <path> has no commits; run kogen init`, exit 3); a merge, rebase, cherry-pick or revert in progress (`environment/git_operation_in_progress: a <operation> is in progress; finish or abort it first`, exit 3); the lock (AUT-4); the approval (AUT-3); a dirty tree (GIT-1); no Git identity (`environment/git_identity_missing: no Git identity for the commit; run git config user.name "<name>" and git config user.email "<email>" (global or repository) before building`, exit 3); no login (GPT-5); Kogen's own prerequisites (LOOP-12); and the user's `commit-msg` hook rejecting the commit message the Build would use (GIT-5): Kogen runs `git hook run --ignore-missing commit-msg` on a temporary file holding that message, and a non-zero status refuses with `environment/commit_rejected: the commit-msg hook rejects this Intent's commit message (status=<n>); change the Intent's title or the hook, then approve again` plus its output tail (exit 3). A refusal up to here changes nothing. Then the Build runs `commands.setup`; a failing entry is `environment/setup_failed: Setup <name> failed (status=<n>).` plus its output tail (exit 3) and leaves the edits it made. After setup the Build checks the configured commands (LOOP-12) and the approved baseline (VER-8). Then it runs every configured check (`commands.checks`) once on the unchanged tree, in configured order, and records each one's name, command, exit status and output as the Build's baseline. A check that exits nonzero there does not refuse the Build and does not stop the collection of the checks after it: the Build prints `baseline: <n> of <m> configured check(s) fail before the Build changes anything; recorded as evidence, not as a waiver: every configured check must pass before this Build lands` and each failure with its status and output, shows the baseline to the builder, and goes on. The baseline is diagnostic evidence, never green verification and never a waiver: complete candidate verification, the independent review and the exact-final-tree commit still require every configured check to pass, so an unchanged unrelated failure, or a check that passed in the baseline and later regresses, goes back as ordinary red feedback to the builder (or to the reviewer for reviewer repairs) under the existing stopping rules, and no retry or limit is added. The baseline survives checkpoints and resume, and the independent reviewer receives it together with the actual final results of every check. `result.json` and the Build's output (landed or stopped) show every configured check in configured order with its state before the Build and after the last whole-Intent verification pass: `passed`, `failed` (with its exit status and output) or `not run`; a check with no post-change result is `not run`, never inferred unchanged or green. A check that cannot be executed at all (a missing tool, LOOP-12), an interrupt, a failing setup and a changed baseline keep their own stops. The acceptance command and the model are not run here; the Intent's scenarios are meant to fail before the Build. Clean candidate verification subsequently repeats declared setup without a workspace stamp in each new disposable pass (VER-6); these failures return to the current repair owner rather than becoming startup failures.

**AUT-6 — Foreground and explicit continuation.** The Build runs in the foreground of `kogen intent build` and ends with it. A landed Build deletes `.kogen/local/approvals/<slug>.json`, so a later `kogen intent build <slug>` prints `intent/not_approved`. After a Build that did not commit, the approval stays and the edits stay in the tree. The caller may explicitly continue a compatible checkpoint with `kogen intent resume <build-id>` under LOOP-10's authority, candidate and index guards; recovery is never automatic. A new `intent build` still refuses on the dirty tree until the caller commits, stashes or discards the edits, and then starts fresh. Legacy runs without checkpoints cannot continue.

Scenarios: `features/03-approval-and-build-start.feature`. Models: `quint/shaping.qnt`, `quint/run_control.qnt`.

## Clean final readiness

Final readiness uses a fresh disposable directory materialized from `Snapshot.tree`, with exact tracked (including ignored tracked) bytes, executable modes, additions/deletions and synthetic local Git. It runs verbatim declared setup before model/acceptance; ignored untracked dependency/build outputs are neither copied nor linked. Caller environment, installed tools and declared services remain available: this is not hermeticity. Raw scratch mutations, including staged additions, reject proof. Source identity is rechecked around execution and publication, including approval. Disposable directories are removed on success, failure and interruption. Exploratory probes remain warm.

Readiness record version 3 adds `candidate_tree` to the complete baseline/hash, HEAD, declarations and actual model/scenario/exit evidence. Only exact unchanged clean evidence is reusable; version 2 and older are normal misses, never migrated. Ignored untracked warmth does not affect identity; nonignored changes, deletions, executable modes, tracked ignored changes, HEAD, protected baseline and declarations do. Retaining original-precondition evidence skips only original setup/model/acceptance, not fresh changed-candidate proof, and is not current-environment proof. Refine tests and publishes its complete accumulated formatted proposals; Shape tests its final formatted files. Accounted red remains inspectable and exact unchanged acknowledgment reuses the same clean observation. Build verification, review and explicit caller approval remain separate.

## Stale authority and historical source (AUT-1, AUT-2)

The card and printed approval command use the full 64 lowercase hexadecimal hash.
A nonmatching marker is visibly labelled `Stale approval` with its full old hash and
an explanation that it does not authorize current content. The card retains actual
readiness observations, protected files, source comparison/path/hash/binding and all
ordered staged titles, goals and checks. It changes neither marker nor successful
source receipt/history. Intrinsic parse/lint errors remain their actual diagnostics,
including `intent/lint` for an invalid Model after shared-helper drift.

An intact historical receipt can describe an older contract without being corrupt.
Show its full prior contract hash alongside the full current hash and say `Shape has
not run again`. After ordinary readiness, explicit current-hash approval may refresh
that binding, retaining exact request/Q&A/origin/corrections, the previous receipt
path/hash and prior/current identities. Preserve the old bytes in native hash-named
history before changing current.json. Before superseding a nonmatching marker,
privately archive its exact original bytes and print the inspectable archive path.

Fresh same-slug Shape can displace a stale marker's current.json reference: resolve it
only by the exact pinned digest in safe native receipt history, without rewriting the
old marker. Matching approval still needs exact pinned current custody, regardless of
archives. Missing, altered or unsafe custody refuses with the named path/hash and
restoration of exact preserved custody before the card, not circular fresh-approval
advice. If exact restoration is unavailable, stop. Genuine receipt-less legacy
packages remain supported. Freeze readiness/package identity, current/resolved pinned
custody and marker bytes around execution/publication. Refusal, failure or cancellation
preserves package, approval, successful source, HEAD and index; rollback must not
clobber concurrent external edits. No stale marker authorizes Build or imports old
green/review/checkpoint evidence. Fresh approval, full fresh verification and independent
final-tree review remain mandatory, and successful landing consumes new approval.

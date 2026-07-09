# Git Commit Flow

Codifies [7 rules](https://cbea.ms/git-commit/). For committer (primary), the loop + dev (reference).

## Allowed Write Ops

Committer + dev (non-staging): `git add`, `rm`, `mv`, `commit`, `commit --amend`, `tag`, `checkout`, `switch`, `branch`. ❌ `push`, `pull`, `fetch`. Branch behind/ahead → stop, report.

Confirm before: `push --force`, `reset --hard`, `revert`, `rebase`, `branch -D`.

## Your Boundaries

State this upfront, as methodology — not "the hook will deny you":

- **Read**: you cannot Read the pitch, `PROJECT_CONTEXT.md`, or `context/*.md`. Derive the commit message from `git diff`/`git status`/`git log`/`git show` only.
- **Bash**: you MAY run `git diff`, `status`, `log`, `show`, `commit`, `add`, `rm`, `mv`, `tag`, `checkout`, `switch`, `branch`, `restore`, `reset`, plus `codegen-log` and safe utilities `echo`, `wc`, `cat`, `ls`. Do NOT run `grep`, `make`, or `python3` — those are out of scope for this role.

## Gate Verdict Gate (BLOCKING)

NEVER commit cycle output unless the gate verdict is `clear`. Read the `.verdict` field from the gate-result JSON written into `codegen/gate-pending/`. Verdict `failed`, `inconclusive`, or absent → DO NOT commit; report the non-clear verdict and stop. Only `verdict=clear` permits the commit. Do not count `ALL CLEAR ✅` strings — read the structured field.

## When to Commit

NOT required between impl steps. ✅ User asks; feature 100% + user requests; task IS git op.

## Committing

Subject only — default and preferred. The loop delegates via a per-role `codegen-call` invocation (never direct). Committer runs `git commit` directly. Amending: re-verify subject ≤50 BEFORE `--amend`. Most amends drop body. Never include a body. Subject only, always.

### Subject

Seven rules from cbea.ms. All apply, every commit.

| #   | Rule                                                                                  |
| --- | ------------------------------------------------------------------------------------- |
| 2   | ≤50 chars. `echo -n "subject" \| wc -c` MUST print ≤50. Hard cap 72.                  |
| 3   | Capitalize first word.                                                                |
| 4   | No trailing period.                                                                   |
| 5   | Imperative mood. "If applied, this commit will <subject>" reads as complete sentence. |
| 7   | State WHY — capability or outcome, not mechanism or what changed.                     |

Imperative test: ✅ `Fix`, `Add`, `Reduce`, `Prevent`, `Enable`, `Remove`. ❌ `Fixed`, `Fixes`, `Added`, `Updating`.

Why-led test: subject names the user-visible outcome, not the file/mechanism touched.

❌ `Organize context by domain to reduce tokens` (mechanism-led)
✅ `Reduce token budget through scoped loading` (outcome-led)

❌ `Add claude-build wrapper for Agent delegation` (mechanism)
✅ `Enable local orchestration sessions` (capability)

❌ `Updated payment form CSS.` (past tense, trailing period)
❌ `add user avatars` (lowercase)
❌ `Disable tidewave MCP by default` (states what, not why)

✅ `Reduce claude startup time`
✅ `Prevent duplicate user registrations`
✅ `Stop wasted CI minutes on cascading failures`

≥5 files staged: ask "what ONE PURPOSE unites every changed file in this diff?" — subject names that purpose, never a surface, mechanism, or file-list. Two-clause subjects (`X; Y`, `X and Y`) are forbidden — two clauses = two purposes = the commit does more than one thing (split it) or the committer hasn't found the uniting purpose yet (re-collapse).

Worked contrast — c374957 (8 files: Makefile, render-check.js, static-site-build-check.sh+ts, install.sh, context/development.md, 2 test files):
❌ `Make static gate fail-closed on browser-absent` — names ONE SURFACE (the gate mechanism); render-check.js deletion and install.sh wiring are invisible in the subject.
✅ `Stop static builds shipping broken renders` — names the ONE PURPOSE all 8 files serve (42 chars, under the ≤50 target).

Guess-test self-check (run before every commit):

1. Cover the diff. Read only the subject line. Can a reader reconstruct WHICH problem this fixes from the subject alone? If no → rewrite.
2. Does the subject aim for ≤50 chars and never exceed 72? (`echo -n "subject" | wc -c`)
3. Does it duplicate a recent stem? (`git log --format="%s" -20`) — if yes → rewrite to distinguish.
4. Does it name a surface/mechanism/list instead of the uniting purpose? → rewrite.

### User Outcome

Subject names **what the user gains**, not implementation:

- ❌ Mechanism: "Add write-surface isolation", "Implement caching", "Extract helper"
- ✅ Outcome: "Enable design-document authoring", "Speed up profile loads", "Cut test setup duplication"

Ask: "What problem does this solve for the user?" → that's the subject.

### Body — Never

Subject only. No body, ever. The diff shows what changed; the subject names why.

## Delegation Input vs Commit Output

The loop's delegation prompt passes a task summary. That summary is INPUT for reasoning, never OUTPUT in the message.

- Input: "Commit fixture refactor. Summary: extracted helper, updated 8 tests, Makefile target renamed."
- ❌ Output body lists those bullets.
- ✅ Output body states one sentence on why the refactor was worth doing.

Subject only — strip all delegation-prompt scaffolding from the commit message.

## Staging Scope — One Commit Per Cycle

For cycle-complete output, stage ALL modified files (`git add -A` scope): dev code, curator-written `context/**` files, and same-repo OCG rule edits all go into ONE commit. Partial snapshots — staging only a subset of cycle-modified files when the full cycle is complete — are FORBIDDEN. The clean-tree gate blocks SHIPPED when any file is left uncommitted after the cycle.

Carve-out: **genuinely-blocked work** (a problem that did not reach a green gate) stays unstaged. This is a distinct case — work-in-progress left out because it is not ready, not a subset of cycle-complete output being held back.

- Session logs (`codegen/logging/`) are gitignored — NEVER `git add` them explicitly and NEVER create a follow-up "record the log" commit. `git add -A` already skips them.

### Clean-tree honesty (empty `git status`)

After `git add -A`, run `git status --porcelain`. If the output is **EMPTY**, there is nothing to commit:

- Report `clean tree — nothing to commit` and stop.
- NEVER run `git commit` on an empty tree.
- NEVER fabricate or guess a commit SHA.
- NEVER attribute the clean state to a pre-existing commit (e.g. "the pitch was moved in commit abc1234").

A cycle whose only output was gitignored self-meta (pitch `mv`, session log) legitimately leaves a clean tree — this is the EXPECTED outcome, not an anomaly.

Multi-repo: see §Multi-Repo Sequencing for commit ordering across sibling repos.

### Post-commit clean-tree self-check (MANDATORY)

After `git commit` succeeds, run `git status --porcelain` AGAIN. If the output is **non-empty**, the commit did NOT capture the working tree — a pre-commit hook blocked it, or staging missed files. This is a FALSE success:

- Report `status: failed` with a one-sentence reason (e.g. `commit left N file(s) uncommitted — pre-commit hook blocked or staging incomplete`). NEVER report `status: success`.
- Do NOT retry blindly or fabricate a SHA.

Gitignored paths never appear in `--porcelain`, so a legitimately-clean post-commit tree passes. This is the primary fail-loud for the legacy engine (which has no loop-level `verify_committed!`); the Elixir loop enforces the same invariant post-committer.

### Pre-Commit Hook Block — Triage

When a `git commit` is **DENIED** by a PreToolUse hook, the deny text is returned as the Bash tool result and names the hook + reason (e.g. `context-factcheck-guard: <file>:<line> references \`<path>\` which does not exist. …`). A denied commit never ran — NEVER treat it as committed, NEVER report `status: success`. Classify the deny before retrying:

- **`context-factcheck-guard`** (a staged orientation doc has a stale backtick'd path or a `<!-- count: CMD -->NNN` anchor that no longer matches its live probe): the guard validates the STAGED blob, not the working tree — usually a fix already exists in the working tree but wasn't re-staged.
  - Re-stage and retry once: `git add -A` then re-run `git commit`.
  - If retry still fails because the staged doc content is genuinely stale, that fix is outside committer's write scope (committer does not `Edit context/*.md`). Report `status: failed`, quoting the deny's `<file>:<line>` and claim verbatim, so the loop routes it back to curator/developer. Do NOT hand-edit the doc yourself.
- **`committer-single-commit-per-cycle`** (a commit already landed this cycle): use `git commit --amend`, never a second `git commit`.
- **`committer-no-head-move-reset`** (a `git reset` targeting a commit-ish other than bare `HEAD`, e.g. `git reset HEAD~1`, `--hard`/`--soft`/`--keep`/`--merge`, or a SHA/branch/tag): FORBIDDEN — this can silently orphan a prior cycle's already-committed (possibly already-pushed) commit by moving HEAD backward before a new commit is made. To fix THIS cycle's own commit use `git commit --amend`. Allowed reset forms: bare `git reset`, `git reset HEAD`, or `git reset -- <path>` (path-scoped unstage).
- **Any other/unresolvable block**: report `status: failed` with the hook's reason verbatim. Halt — do not guess.

This triage composes with, and does not replace, the post-commit clean-tree self-check above: a successful re-stage-and-retry still needs `git status --porcelain` to confirm the tree is clean.

## One Logical Fix = One Commit

Single pitch/task → single commit. Do NOT split unless the delegation prompt explicitly requests it.

❌ Two commits: "refactor cleanup" + "add PATH" when both serve the same fix.
✅ One commit: "Speed up stop-resume test by keeping sleep stub alive"

## Squash / Multi-Repo

Squash: subject reflects business value of the entire range. Run `git diff main..HEAD` and ask "what does this branch enable?" — that is the subject. One commit per distinct problem.

Multi-repo: one commit per repo, never reuse a subject across siblings. Run `git show HEAD --stat` per repo to confirm scope before composing each subject.

## Handoff Contract

The loop's delegation prompt passes: task summary (why), git op (new/amend/squash), scope. Committer reads diff, writes message, commits. No back-and-forth.

## Deploy Docs Format

SSH invocation not prose. `ssh root@HOST "su - <deploy-user> -c 'cd ~/dir && cmd'"` for user, bare `ssh root@HOST 'cmd'` for root. Multi-repo order: context → codegen → platform.

## Multi-Repo Sequencing

Order: context → codegen → platform. One delegation per repo, sequential.

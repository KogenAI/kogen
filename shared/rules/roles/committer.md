# Git Commit Flow

Codifies [7 rules](https://cbea.ms/git-commit/). For committer (primary), orchestrator + dev (reference).

## Allowed Write Ops

Committer + dev (non-staging): `git add`, `rm`, `mv`, `commit`, `commit --amend`, `tag`, `checkout`, `switch`, `branch`. ❌ `push`, `pull`, `fetch`. Branch behind/ahead → stop, report.

Confirm before: `push --force`, `reset --hard`, `revert`, `rebase`, `branch -D`.

## Gate Verdict Gate (BLOCKING)

NEVER commit cycle output unless the gate verdict is `clear`. Read `codegen/gate-pending/gate-result.json` `.verdict`. Verdict `failed`, `inconclusive`, or absent → DO NOT commit; report the non-clear verdict and stop. Only `verdict=clear` permits the commit. Do not count `ALL CLEAR ✅` strings — read the structured field.

## When to Commit

NOT required between impl steps. ✅ User asks; feature 100% + user requests; task IS git op.

## Committing

Subject only — default and preferred. Orchestrator delegates via Agent (never direct). Committer runs `git commit` directly. Amending: re-verify subject ≤50 BEFORE `--amend`. Most amends drop body. Never include a body. Subject only, always.

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

Orchestrator passes a task summary. That summary is INPUT for reasoning, never OUTPUT in the message.

- Input: "Commit fixture refactor. Summary: extracted helper, updated 8 tests, Makefile target renamed."
- ❌ Output body lists those bullets.
- ✅ Output body states one sentence on why the refactor was worth doing.

Subject only — strip all orchestrator scaffolding from the commit message.

## Staging Scope — One Commit Per Cycle

For cycle-complete output, stage ALL modified files (`git add -A` scope): dev code, curator-written `context/**` files, and same-repo OCG rule edits all go into ONE commit. Partial snapshots — staging only a subset of cycle-modified files when the full cycle is complete — are FORBIDDEN. The clean-tree gate blocks SHIPPED when any file is left uncommitted after the cycle.

Carve-out: **genuinely-blocked work** (a problem that did not reach a green gate) stays unstaged. This is a distinct case — work-in-progress left out because it is not ready, not a subset of cycle-complete output being held back.

- Session logs (`codegen/logging/`) are gitignored — NEVER `git add` them explicitly and NEVER create a follow-up "record the log" commit. `git add -A` already skips them.

Multi-repo: see §Multi-Repo Sequencing for commit ordering across sibling repos.

## One Logical Fix = One Commit

Single pitch/task → single commit. Do NOT split unless orchestrator explicitly requests it.

❌ Two commits: "refactor cleanup" + "add PATH" when both serve the same fix.
✅ One commit: "Speed up stop-resume test by keeping sleep stub alive"

## Squash / Multi-Repo

Squash: subject reflects business value of the entire range. Run `git diff main..HEAD` and ask "what does this branch enable?" — that is the subject. One commit per distinct problem.

Multi-repo: one commit per repo, never reuse a subject across siblings. Run `git show HEAD --stat` per repo to confirm scope before composing each subject.

## Handoff Contract

Orchestrator passes: task summary (why), git op (new/amend/squash), scope. Committer reads diff, writes message, commits. No back-and-forth.

## Deploy Docs Format

SSH invocation not prose. `ssh root@HOST "su - <deploy-user> -c 'cd ~/dir && cmd'"` for user, bare `ssh root@HOST 'cmd'` for root. Multi-repo order: context → codegen → platform.

## Multi-Repo Sequencing

Order: context → codegen → platform. One delegation per repo, sequential.

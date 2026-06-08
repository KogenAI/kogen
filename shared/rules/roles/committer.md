# Git Commit Flow

Codifies [7 rules](https://cbea.ms/git-commit/). For committer (primary), orchestrator + dev (reference).

## Allowed Write Ops

Committer + dev (non-staging): `git add`, `rm`, `mv`, `commit`, `commit --amend`, `tag`, `checkout`, `switch`, `branch`. ❌ `push`, `pull`, `fetch`. Branch behind/ahead → stop, report.

Confirm before: `push --force`, `reset --hard`, `revert`, `rebase`, `branch -D`.

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

≥5 files staged: ask "what single problem does the whole diff solve?" — subject names that problem.

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

For cycle-complete output, stage ALL modified files (`git add -A` scope): dev code, curator context edits, and same-repo OCG rule edits all go into ONE commit. Partial snapshots — staging only a subset of cycle-modified files when the full cycle is complete — are FORBIDDEN. The clean-tree gate blocks SHIPPED when any file is left uncommitted after the cycle.

Carve-out: **genuinely-blocked work** (a problem that did not reach a green gate) stays unstaged. This is a distinct case — work-in-progress left out because it is not ready, not a subset of cycle-complete output being held back.

Multi-repo: see §Multi-Repo Sequencing for commit ordering across sibling repos.

## Squash / Multi-Repo

Squash: subject reflects business value of the entire range. Run `git diff main..HEAD` and ask "what does this branch enable?" — that is the subject. One commit per distinct problem.

Multi-repo: one commit per repo, never reuse a subject across siblings. Run `git show HEAD --stat` per repo to confirm scope before composing each subject.

## Handoff Contract

Orchestrator passes: task summary (why), git op (new/amend/squash), scope. Committer reads diff, writes message, commits. No back-and-forth.

## Deploy Docs Format

SSH invocation not prose. `ssh root@HOST "su - combobulate -c 'cd ~/dir && cmd'"` for user, bare `ssh root@HOST 'cmd'` for root. Multi-repo order: context → codegen → platform.

## Multi-Repo Sequencing

Order: context → codegen → platform. One delegation per repo, sequential.

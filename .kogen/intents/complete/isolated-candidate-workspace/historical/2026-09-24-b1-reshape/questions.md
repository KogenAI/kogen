# Open questions

The questions file as it stood before the 2026-09-24 reshape is kept at
`historical/2026-09-22-warm-seed-revision/questions.md`. Its settled
boundaries still hold and are summarized under "Carried forward".

## Open for the Shaper (2026-09-24, B1 reshape)

The Draft currently assumes the recommended answer to each question.

### Q1. Where Candidate worktrees live — settled 2026-09-24

Shaper: "inside Kogen's own tree". CLAUDE.md/AGENTS.md nesting is
unimportant because those files are not wanted in projects; duplicate trees
in the repository are the cost to avoid. The location is
`~/Library/Application Support/Kogen/build-workspaces/<project-id>/`. Tests
redirect the root with `KOGEN_WORKSPACES_ROOT`, like `KOGEN_CLAUDE_ROOT`, so
automated tests never write to the real Kogen directory; the Shaper asked
what this meant and was answered.

### Q2. Kept Candidates: stop message and commands — settled 2026-09-24

The Shaper's answers across three rounds:

- A Kogen command for kept Candidates is wanted, not bare git commands.
- A list command is required: "git worktree list is useless - it doesn't
  show which worktree belongs to which intent and the worktree names are
  obfuscated". Names must be readable and list must show the Intent.
- Publish is dropped: "publish is weird because it's pretty much useless".
  An accepted Build already fast-forwards automatically.
- Remove is added. Guard accepted only: deleting a stopped Candidate's
  uncommitted edits is fine on request, but a Candidate holding an accepted
  commit not reachable from its admitted branch needs `--discard-accepted`.
- Prune is added. Removing orphans left by deleted or moved checkouts, the
  only cross-project action, needs an explicit flag, "because it's an
  unexpected behavior".
- Every command acts on the current project only.

Narrowed after independent review (2026-09-24): the Shaper forwarded a
review recommending cutting `prune` and `--orphans` to make B1 more likely to
land first time, and said "the agent was right / these other commands are
unnecessary for now / we can either add those as part of parallel builds or
even as a separate intent". B1 keeps `mix kogen.candidates` (list) and
`mix kogen.candidates.remove <build-id> [--discard-accepted]`. Prune, orphan
cleanup and the `project.json` they needed are parked in
`.kogen/runtime/shaping-followups/SHAPE_CANDIDATE_PRUNE.md`. They are not
approved backlog. The command names were not vetoed.

The same review's item 3 was also accepted ("the agent was right"): both
live fixtures' `KOGEN_WORKSPACES_ROOT` paths contain a space.

### Q3. The Codex route's hook configuration — settled 2026-09-24

The Shaper chose "Support, document limit": both routes use the same
control-root hook mechanism. It is documented that native Codex reads hook
*configuration* (`.codex/hooks.json`) from the Candidate, which is structural
separation, not hostile containment. Codex routing is proved offline only, and
no `live-native` target is added.

### Parallel Builds in this Intent? — answered, not reopened

The Shaper asked whether B1 allows parallel Builds and how much work adding
them would be, noting: "it might be too much ... when one build has merged
automatically, but then the other one needs to rebase main into it, rerun
the tests, maybe even fix conflicts". Answer: B1 does not allow them; the
global lock stays. B2 needs a per-Build lock and state, same-Intent refusal,
the pinned engine (the 2026-09-23 probe showed a running controller can pick
up code another Build publishes) and serial publication. Without rebase and
re-verification (brief 22), the second of two parallel Builds is kept
unpublished and must be rebuilt, which limits B2's value until integration
exists. The agreed order A → handoff → B1 → B2 stands unless the Shaper says
otherwise.

## Carried forward (settled, not reopened)

- All investigation, integration and repair happen in the Build's own worktree. Unverified
  changes are never installed on `main` to be fixed there.
- When `main` has not moved, publication needs no artificial merge or duplicate
  verification. When it has moved, B1 refuses. Bringing newer `main` into a Candidate needs
  fresh verification and Review and is a later Intent (brief 22).
- Future continuation uses the existing `mix kogen.build <slug>` command, not a separate
  resume command (brief 20). This does not settle its eligibility rules.
- Concurrent Builds, per-Build locks and the pinned engine are B2.
- The control checkout must be clean at publication; all work happens in worktrees
  (2026-09-23).
- No silent fallbacks (2026-09-23).

## Not B1

- Route naming: `decisions.md` (2026-09-23) records the Shaper asking for `claude` and
  `chatgpt`, but the committed config and README name `claude` and `codex`. That belongs to
  the named-routes follow-up, not this Intent.

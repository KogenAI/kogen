# Rules Roles Domain — Role-Specific Behavioral Rules

Role-specific rules that define what each agent role MUST and MUST NOT do. These are distinct from core discipline rules (see `context/rules-core.md`) — they encode delegation contracts, never-implement rules, gate-reading behavior, and role boundaries.

## Components

| File                                    | Purpose                                                                                                    |
| --------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `shared/rules/roles/orchestrator.md`    | Orchestrator-only rules — delegation, never-implement, full-cycle, INCONCLUSIVE table                      |
| `shared/rules/roles/planner.md`         | Planner rules — plan structure, slice definitions, gate-json block format, `__GATE_PARSE_ERROR__` sentinel |
| `shared/rules/roles/developer.md`       | Universal developer rules — verify-not-declare, fix-root-cause, test with every change                     |
| `shared/rules/roles/reviewer.md`        | Reviewer rules — what to check, how to report, block/pass criteria                                         |
| `shared/rules/roles/committer.md`       | Committer rules — commit message format, never amend, why-focused                                          |
| `shared/rules/roles/context-curator.md` | Context curator rules — what to update, when, retrospective routing                                        |
| `context/curator-routing.md`            | Project routing targets for context-curator — where [local]/[shared] learnings land in THIS repo           |

## Key Paths

```
shared/rules/roles/
  orchestrator.md
  planner.md
  developer.md
  reviewer.md
  committer.md
  context-curator.md
```

## Integration Points

- **subagents**: each `.md.j2` template `{% include %}`s its role's rule file — changes require `make install`
- **hooks**: several hooks enforce role rules at runtime — e.g. `orchestrator-no-source-edit.sh` enforces orchestrator's never-implement rule; `pre-commit-guard.sh` enforces committer-only commits; `curator-before-committer.sh` enforces reviewer → curator → committer sequencing — see `context/hooks.md`
- **rules-core**: role rules are layered on top of core discipline rules (`context/rules-core.md`); both must be satisfied
- **scaffold**: `AGENTS-phoenix.md.j2` and `AGENTS-static.md.j2` embed orchestrator rules for downstream apps — sync burden when orchestrator.md changes; see `context/scaffold.md`
- **curator-routing**: context-curator's generic rule (`shared/rules/roles/context-curator.md`) defines the write surface and decision tree — see § Curator Write Surface below; `context/curator-routing.md` carries project-specific path targets; `codegen/rules/` is a symlink to `shared/rules/` — all curators edit via the symlink path `codegen/rules/**`, never via `shared/rules/` directly

## Curator Write Surface

The guard `context-curator-guard.sh` enforces exactly three allowed path patterns (line numbers in the hook source):

- Line 46: `(^|/)context/` — allows `context/*.md` relative to any project root (all repos)
- Line 51: `(^|/)codegen/rules(/|$)` — allows `codegen/rules/**` symlink path (all repos; symlink target is `<codegen-repo>/shared/rules`)
- Line 56: `(^|/)codegen/logging/` — allows `codegen/logging/*.md` session logs (codegen-on-codegen only)

**Path-nesting note**: all curators use `codegen/rules/**` (the symlink path). Direct `shared/rules/` edits are DENIED — the guard does not allow them. Hook receives raw symlink path (not resolved target). Boundary: `codegen/recipes/` and `codegen/rulesets/` still DENIED — pattern anchors on `/rules(/|$)`.

**Propagation difference**:

- `context/*.md` — checked-in file; sticks on commit; `make install` never touches it.
- `codegen/rules/**` — symlink to `shared/rules/`; source for `{% include %}` in `.md.j2` templates; edit is inert until `make install` re-renders agent prompts and installs them to `~/.claude/`.

**Decision tree** (determines where a `[shared]` learning goes):

1. Learning is about hooks, enforcement, generator pipeline, or framework mechanics (already captured in agent-readable context data) → `context/*.md` — commit, no regeneration.
2. Learning requires a new rule or discipline edit in `shared/rules/**`:
   - Downstream repo → edit `codegen/rules/<path>` via symlink path (guard allows it); note `make install` must run in codegen repo before agents see the change.
   - Codegen-on-codegen → edit `codegen/rules/<path>` via symlink path (guard allows it); note `make install` required before agents see the change. Rule edits should be deferred to framework-focused sessions, not routine curation cycles.
3. Learning is project-specific (module names, file paths, business logic) → skip; out of curator scope.

Cross-reference: full guard pattern analysis and path-nesting mechanics → `context/hooks.md` § context-curator-guard Write Surface; rule text → `shared/rules/roles/context-curator.md` § Write Surface.

## Committer Spawn Timing

Committer is a leaf agent with no independent decision-making power about when it runs. Ordering enforcement happens in two layers:

1. **Orchestrator prompt** — all four cycle statements in `harnesses/<harness>/tools-header/build.txt` name the full sequence: `reviewer → context-curator → committer`. This is the primary guidance.
2. **Spawn-time guard** — `curator-before-committer.sh` (Claude) and `.ts` mirror (Pi) block committer spawning when reviewer section is present in the active step log but curator section is absent. Provides hard enforcement at the moment delegation is attempted.

**Fail-open principle**: both Claude and Pi spawn guards check the active session log (discovered via transcript analysis). If the log is missing, unreadable, or cannot be parsed, the guard exits successfully (allow the spawn). This is deliberate — missing evidence should not block action. The prompt guidance is the primary enforcer; the guard is a backstop to catch obvious out-of-order violations. If session logs are inaccessible, fall back to orchestrator prompt guidance.

## Trigger Keywords

orchestrator rules, planner rules, developer rules, reviewer rules, committer rules, context-curator rules, never-implement, full-cycle, delegation, INCONCLUSIVE table

## Pitfalls

- **Rule changes are not live** — must `make install` to regenerate agent prompts
- **`AGENTS-*.md.j2` embeds orchestrator rules** — downstream app templates in `shared/apps/` carry a copy of orchestrator rules; when `orchestrator.md` changes, update those templates too
- **Dev prompt boundary** — the developer delegation prompt ends at the gate. Orchestrator must NEVER fold "Commit via committer" / `make install` / deploy into the dev prompt; commit is a separate post-reviewer+curator cycle stage the orchestrator owns. Root cause of past drift: orchestrator misread the `tools-header/build.txt` responsibilities line ("Commit via committer") as a step to relay to the dev. Sync sites carrying this rule: `shared/rules/roles/orchestrator.md` (canonical), `harnesses/{claude,pi}/tools-header/build.txt` (responsibilities one-liner), `shared/apps/AGENTS-{phoenix,static}.md.j2`.
- **Role identity at runtime** — hooks use two discriminators: `AGENT_TYPE` (per-subagent identity, set per-spawn) and `CLAUDE_ROLE_FAMILY` (per-launcher mode, set by outer session harness). `AGENT_TYPE` is used for per-role guards on subagents; `CLAUDE_ROLE_FAMILY` is used for `claude-debug`/`claude-shape`/`claude-refactor` session-level guards. Not all hooks use both — check each hook's discriminator before assuming universal `$AGENT_TYPE` behavior

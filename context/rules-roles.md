# Rules Roles Domain — Role-Specific Behavioral Rules

Role-specific rules that define what each agent role MUST and MUST NOT do. These are distinct from core discipline rules (see `context/rules-core.md`) — they encode delegation contracts, never-implement rules, gate-reading behavior, and role boundaries.

## Components

| File                                    | Purpose                                                                                          |
| --------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `shared/rules/roles/orchestrator.md`    | Orchestrator-only rules — delegation, never-implement, full-cycle, INCONCLUSIVE table            |
| `shared/rules/roles/planner.md`         | Planner rules — plan structure, slice definitions, gate command                                  |
| `shared/rules/roles/developer.md`       | Universal developer rules — verify-not-declare, fix-root-cause, test with every change           |
| `shared/rules/roles/reviewer.md`        | Reviewer rules — what to check, how to report, block/pass criteria                               |
| `shared/rules/roles/committer.md`       | Committer rules — commit message format, never amend, why-focused                                |
| `shared/rules/roles/context-curator.md` | Context curator rules — what to update, when, retrospective routing                              |
| `context/curator-routing.md`            | Project routing targets for context-curator — where [local]/[shared] learnings land in THIS repo |

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
- **hooks**: several hooks enforce role rules at runtime — e.g. `orchestrator-no-source-edit.sh` enforces orchestrator's never-implement rule; `pre-commit-guard.sh` enforces committer-only commits — see `context/hooks.md`
- **rules-core**: role rules are layered on top of core discipline rules (`context/rules-core.md`); both must be satisfied
- **scaffold**: `AGENTS-phoenix.md.j2` and `AGENTS-static.md.j2` embed orchestrator rules for downstream apps — sync burden when orchestrator.md changes; see `context/scaffold.md`
- **curator-routing**: context-curator's generic rule (`shared/rules/roles/context-curator.md`) delegates project paths to `context/curator-routing.md` — the `[shared]` write surface on disk is `shared/rules/**`; `codegen/rules/` is a symlink to `shared/rules/` created by `make install` and must NOT be edited directly

## Trigger Keywords

orchestrator rules, planner rules, developer rules, reviewer rules, committer rules, context-curator rules, never-implement, full-cycle, delegation, INCONCLUSIVE table

## Pitfalls

- **Rule changes are not live** — must `make install` to regenerate agent prompts
- **`AGENTS-*.md.j2` embeds orchestrator rules** — downstream app templates in `shared/apps/` carry a copy of orchestrator rules; when `orchestrator.md` changes, update those templates too
- **Role identity at runtime** — hooks use two discriminators: `AGENT_TYPE` (per-subagent identity, set per-spawn) and `CLAUDE_ROLE_FAMILY` (per-launcher mode, set by outer session harness). `AGENT_TYPE` is used for per-role guards on subagents; `CLAUDE_ROLE_FAMILY` is used for `claude-debug`/`claude-shape`/`claude-refactor` session-level guards. Not all hooks use both — check each hook's discriminator before assuming universal `$AGENT_TYPE` behavior

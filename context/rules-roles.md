# Rules Roles Domain — Role-Specific Behavioral Rules

Role-specific rules that define what each agent role MUST and MUST NOT do. These are distinct from core discipline rules (see `context/rules-core.md`) — they encode delegation contracts, never-implement rules, gate-reading behavior, and role boundaries.

## Components

| File                                    | Purpose                                                                                |
| --------------------------------------- | -------------------------------------------------------------------------------------- |
| `shared/rules/roles/orchestrator.md`    | Orchestrator-only rules — delegation, never-implement, full-cycle, INCONCLUSIVE table  |
| `shared/rules/roles/planner.md`         | Planner rules — plan structure, slice definitions, gate command                        |
| `shared/rules/roles/developer.md`       | Universal developer rules — verify-not-declare, fix-root-cause, test with every change |
| `shared/rules/roles/reviewer.md`        | Reviewer rules — what to check, how to report, block/pass criteria                     |
| `shared/rules/roles/committer.md`       | Committer rules — commit message format, never amend, why-focused                      |
| `shared/rules/roles/context-curator.md` | Context curator rules — what to update, when, retrospective routing                    |

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

## Trigger Keywords

orchestrator rules, planner rules, developer rules, reviewer rules, committer rules, context-curator rules, never-implement, full-cycle, delegation, INCONCLUSIVE table

## Pitfalls

- **Rule changes are not live** — must `make install` to regenerate agent prompts
- **`AGENTS-*.md.j2` embeds orchestrator rules** — downstream app templates in `shared/apps/` carry a copy of orchestrator rules; when `orchestrator.md` changes, update those templates too
- **Role identity at runtime** — hooks detect role by reading `$AGENT_TYPE` env var set by the launcher; wrong role assignment causes wrong hook enforcement

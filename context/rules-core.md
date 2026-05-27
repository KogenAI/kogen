# Rules Core Domain — Cross-Cutting Discipline Rules

Core discipline rules that apply to ALL agents regardless of role or stack. These files are `{% include %}`d into every subagent template — they encode the baseline behavioral contract every agent must follow.

## Components

| File                                    | Purpose                                                                |
| --------------------------------------- | ---------------------------------------------------------------------- |
| `shared/rules/INDEX.md`                 | Registry — file → trigger keywords; loaded by orchestrators/planners   |
| `shared/rules/STYLE_GUIDE.md`           | Cross-cutting style rules for all agents                               |
| `shared/rules/_core/bash-discipline.md` | Forbidden bash patterns, token-budget rules, safe alternatives         |
| `shared/rules/_core/output-style.md`    | Caveman Ultra output compression rules                                 |
| `shared/rules/_core/session-log.md`     | Session log format, ownership, section headers, subagent body template |
| `shared/rules/_core/cwd-discipline.md`  | Working-directory rules — no /tmp writes, absolute paths only          |

## Key Paths

```
shared/rules/
  INDEX.md
  STYLE_GUIDE.md
  _core/
    bash-discipline.md
    output-style.md
    session-log.md
    cwd-discipline.md
```

## Integration Points

- **subagents**: every `.md.j2` template `{% include %}`s these files — changes require `make install` to propagate
- **hooks**: some hooks enforce these rules at runtime (e.g. `no-python-json.sh` enforces `bash-discipline.md`; `no-cat-pipe.sh` enforces pipe patterns) — see `context/hooks.md`
- **rules-roles**: role rules are layered on top of these core rules; core rules define the floor
- **INDEX.md must stay in sync** — each rule file must have an INDEX row or orchestrators won't load it on demand

## Trigger Keywords

bash-discipline, output-style, session-log, cwd-discipline, STYLE_GUIDE, INDEX.md

## Pitfalls

- **Rule changes are not live** — must `make install` to regenerate agent prompts; running agents see old baked rules
- **INDEX.md must stay in sync** — adding a rule file without an INDEX row means orchestrators won't load it on demand
- **`@apply` in rules is Tailwind-context only** — static site rules reference Tailwind `@apply`; don't confuse with CSS `@apply`

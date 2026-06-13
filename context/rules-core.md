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

- **subagents**: `_core` rules are `{% include %}`d selectively per role — NOT every subagent includes all 4. Developer templates (via `_phoenix_developer_common.md.j2` / `_static_developer_common.md.j2`) include all 4. Planners include 3 (omit `cwd-discipline`). Committers include only `output-style` + `bash-discipline`. Check each `.md.j2` template for exact includes. Changes require `make install` to propagate
- **shape spine**: The authoring spine (`_authoring-spine.txt`, included in shape mode body) enforces the "plain-language discipline" rule (Rule B), which cites `output-style.md` § Verbatim to define protected literal categories (code blocks, error strings, JSON field names, `MUST`/`NEVER`/`FORBIDDEN`, gate markers). The rule allows these literals to appear verbatim in user-facing prose while suppressing other internal shorthand.
- **hooks**: some hooks enforce these rules at runtime (e.g. `no-python-json.sh` enforces `bash-discipline.md`; `no-cat-pipe.sh` enforces pipe patterns) — see `context/hooks.md`
- **rules-roles**: role rules are layered on top of these core rules; core rules define the floor
- **INDEX.md must stay in sync** — each rule file must have an INDEX row or orchestrators won't load it on demand

## Trigger Keywords

bash-discipline, output-style, session-log, cwd-discipline, STYLE_GUIDE, INDEX.md

## POSIX Awk Patterns

**Uninitialized variable defaults**: POSIX awk initializes unset scalar variables to 0 (numeric context) or empty string (string context). Safe pattern for block-scoped search functions: `exit !found` at END correctly exits 1 (not found) when no matching line was found, without requiring explicit `found=0` initialization at the top. This works in all awk implementations including mawk (Debian default).

## Shared Rule Prose — Harness-Neutral & Consumer-Agnostic Language

Rules in `shared/rules/shared/` (and cross-referenced by downstream projects) must never name harness-specific binaries or codegen-internal dispatch mechanisms. These rules are baked into agent prompts executed in downstream projects where the named binaries may not exist.

**Anti-patterns**:

- ❌ `claude` / `pi` (harness binary names)
- ❌ `codegen-call` (codegen-internal dispatcher)
- ❌ `claude -p` / `pi -p` (harness-specific CLI flags)

**Harness-neutral equivalents**:

- ✅ "nested subprocess" (covers any role-spawning mechanism)
- ✅ `--print` (flag name is neutral; flag semantics apply to all harnesses)

The carve-out parenthetical is the most error-prone location for this slip — ensure any exception allowing subprocess invocation uses the neutral form. Example: "This does NOT forbid a print-mode subprocess (`--print`) your delegation prompt explicitly asks for — e.g. verifying a build, or testing a role you are editing."

## Pitfalls

- **Rule changes are not live** — must `make install` to regenerate agent prompts; running agents see old baked rules
- **INDEX.md must stay in sync** — adding a rule file without an INDEX row means orchestrators won't load it on demand
- **`@apply` in rules is Tailwind-context only** — static site rules reference Tailwind `@apply`; don't confuse with CSS `@apply`
- **Shared rules must be harness-agnostic** — no launcher/dispatcher binary names in files under `shared/rules/shared/` or symlink-included rules; these are baked into downstream agent prompts

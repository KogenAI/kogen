# Subagents Domain — Subagent Templates + Roles

The subagents domain owns the `.md.j2` Jinja-style templates that `generate.sh` renders into per-harness agent prompt files. Each template uses `{% include %}` to inline rules, recipes, and common fragments — producing a self-contained system prompt baked at install time. Subagents never re-read rules at runtime; everything is pre-loaded into the rendered `.md`.

Two common fragments (`_phoenix_developer_common.md.j2`, `_static_developer_common.md.j2`) deduplicate shared backend/frontend developer rules.

## Components

| File                                                        | Purpose                                                                         |
| ----------------------------------------------------------- | ------------------------------------------------------------------------------- |
| `shared/subagents/phoenix/planner-phoenix.md.j2`            | Phoenix planner — reads codebase, writes structured plan                        |
| `shared/subagents/phoenix/developer-phoenix-backend.md.j2`  | Backend developer — schemas, contexts, migrations, Oban                         |
| `shared/subagents/phoenix/developer-phoenix-frontend.md.j2` | Frontend developer — LiveView, HEEx, JS hooks, Tailwind                         |
| `shared/subagents/phoenix/reviewer-phoenix.md.j2`           | Phoenix reviewer — quality, patterns, architecture                              |
| `shared/subagents/static/developer-html.md.j2`              | Plain HTML + Tailwind v4 developer                                              |
| `shared/subagents/static/developer-hugo.md.j2`              | Hugo static site developer                                                      |
| `shared/subagents/static/developer-vite.md.j2`              | Vite static site developer — covers React, Vue, and Svelte component-based apps |
| `shared/subagents/static/planner-html.md.j2`                | HTML stack planner                                                              |
| `shared/subagents/static/planner-hugo.md.j2`                | Hugo stack planner                                                              |
| `shared/subagents/static/planner-vite.md.j2`                | Vite stack planner                                                              |
| `shared/subagents/static/reviewer-static.md.j2`             | Static site reviewer                                                            |
| `shared/subagents/shared/committer.md.j2`                   | Committer — analyzes diff, crafts why-focused commit message                    |
| `shared/subagents/shared/context-curator.md.j2`             | Context curator — updates domain context files post-reviewer                    |
| `shared/subagents/_phoenix_developer_common.md.j2`          | Shared rules fragment included by backend + frontend templates                  |
| `shared/subagents/_static_developer_common.md.j2`           | Shared rules fragment included by all static developer templates                |

## Key Paths

```
shared/subagents/
  _phoenix_developer_common.md.j2
  _static_developer_common.md.j2
  phoenix/
    planner-phoenix.md.j2
    developer-phoenix-backend.md.j2
    developer-phoenix-frontend.md.j2
    reviewer-phoenix.md.j2
  static/
    developer-html.md.j2, developer-hugo.md.j2, developer-vite.md.j2  ← React/Vue/Svelte
    planner-html.md.j2, planner-hugo.md.j2, planner-vite.md.j2
    reviewer-static.md.j2
  shared/
    committer.md.j2
    context-curator.md.j2
```

Generated output lands in `templates/generated/<harness>/` then installed to `~/.claude/agents/` or equivalent.

## Integration Points

- **core**: `generate.sh` + `process_template.py` render these templates; output goes to `templates/generated/`
- **rules**: templates `{% include %}` rule files from `shared/rules/` — rule changes require re-running `make install`; behavioral rules for each role are documented in `context/rules-roles.md`; these templates are the wiring mechanism, not the rules themselves
- **harnesses**: each harness may have harness-specific includes; claude harness renders phoenix + static; pi harness renders from the same `shared/subagents/` tree unless it has overrides in `harnesses/pi/`
- **scaffold**: `shared/apps/AGENTS-phoenix.md.j2` and `AGENTS-static.md.j2` are downstream AGENTS.md templates (separate from subagent templates here)
- **commands**: slash commands in `harnesses/claude/commands/` can spawn subagent swarms (e.g., `/poke-holes` spawns Explore agents to stress-test a pitch). Spawned subagents must satisfy role allowlist in `operator-subagent-allowlist.sh` (debug, shape, refactor, ops roles only).

## Authoring Spine Rules (Shape/Refactor)

The `shared/prompt-fragments/_authoring-spine.txt` is included in both `shape.txt` and `refactor.txt` mode bodies. It encodes the investigative readiness loop that gates pitch advancement (Phase 0 context load → multi-turn investigation → readiness check before writing). Twelve core rules govern this loop:

**Rule A: Intent-guard before AskUserQuestion** — before emitting any question, check whether every proposed option preserves the pitch's core intent. Any option that would undo the primary claim or nullify the stated goal is FORBIDDEN; auto-narrow coverage instead of offering null options.

**Rule B: Plain-language discipline** — suppress internal shorthand (bare flags, internal probe names, unqualified identifiers, file paths, line numbers) in user-facing prose. Describe what something does. Exception: protected literals (`shared/rules/_core/output-style.md` § Verbatim) stay verbatim — code blocks, error strings, JSON field names, `MUST`/`NEVER`/`FORBIDDEN`, gate markers.

**Rule C: Command-level pairing auto-cover** — a claude-X launcher (claude-shape, etc.) always auto-includes its pi-X counterpart (pi-shape, etc.) as same-change coverage. Never ask "should I cover both harnesses?"; the answer is always yes.

**Rule D: Duplication-detection Phase-0 step** — during the blast-radius scan, grep for logic equivalent to the proposed change elsewhere in the codebase. If found, EXTRACTION (consolidating at the existing site) is the default proposal, never duplicate implementations. Auto-decide without asking.

**Rule E: Symptom-vs-target discipline** — when user names both a SYMPTOM (observed bad behavior) and a TARGET (thing to improve), the TARGET is the investigation subject. Probe the symptom ONCE to confirm origin, then pivot immediately to the target. Never let symptom-chasing displace target investigation.

**Rule F: Context-drift auto-cover** — when Phase 0 reveals a `context/*.md` file that disagrees with actual codebase state, auto-include that stale context file in the edit surface. Never ask whether to update it; including it is automatic.

**Rule G: Decompose-then-split** — when a problem is too large to build in one focused pass (spans multiple independent surfaces or requires prerequisites that don't exist yet), the shaper SPLITS it into N independently-buildable pitches ITSELF. It does NOT ask the user "should I split this?" or "how should I split this?". Splitting is an engineering-decomposition decision the shaper makes by reading code and dependency structure. Emit one chat line naming what was split: `Decomposed: extracted pitches <slug-1>, <slug-2> …`. This generalizes the dedup-extraction default (Rule D) from "extract on duplication" to "extract on scope". The ONLY split-related question that reaches the user is a genuine product fork the decomposition reveals.

**Rule H: Derive-and-write dependency edges** — when splitting, the shaper DERIVES the build-order dependencies by reading what each extracted pitch consumes that another produces, and WRITES them as `Blocks-on: <slug>` lines into each pitch's `## Dependencies` block. The dashboard topo-sorts these declared edges but performs zero inference of its own — an omitted edge silently mis-orders. Never ask "what depends on what?"; derive by reading code. The `## Dependencies` grammar is already shipped in `pitch-format-contract.md`. Every split MUST leave correct, parseable `## Dependencies` blocks behind.

**Rule I: Ask-vs-decide classifier (Shape mode)** — ask the user ONLY when the answer changes what they experience or names something they own: UX copy/flow/behavior, product-intent forks (feature A vs feature B), or naming/identity they control. Test: "Does the answer change what the user experiences or names something the user owns?" If no → auto-decide from code + convention. Engineering-completeness decisions are NOT user decisions (install-guarantee, fail-closed-when-guaranteed, internal naming, split mechanics) → auto-decide and record as `Assumed: <dimension> = <default> (override if wrong)` in the end-summary.

**Rule J: Deferral-with-draft contract** — every deferral (any "deferred", "future work", "phase 2", "out of scope", "accepted risk") MUST be backed by a real `codegen/pitches/draft/<slug>.md` file. The pitch references the draft; a prose-only deferral is a blocker. Security/safety deferrals (auth, access control, secrets, data deletion) must additionally state the exposure assumption in the draft's rationale (e.g., "safe to defer only while the box is unreachable").

These rules are baked into the shape system prompt at install time. Changes to `_authoring-spine.txt` require `make install` to propagate.

## Deletion-Safety Blocker Classes (Shape)

Shape mode gates pitch readiness by scanning for three deletion-safety blocker classes:

- **Un-investigated rabbit holes** — a Rabbit holes entry or deferred unknown with no probe transcript and no draft-pitch backing. Every deferral must be backed by a `codegen/pitches/draft/<slug>.md` file (Rule J: deferral-with-draft contract). Security/safety-relevant deferrals must additionally state the exposure assumption they rest on. Prose-only deferrals are blockers, not resolutions.
- **Untraced edit surface / deletion claim** — a file named as an edit target or as deletable, with no provenance probe confirming its relevance.
- **Dangling cross-reference** — every `## Related pitches` entry must reference a file on disk in `codegen/pitches/{draft,ready,shipped}/`; unresolved references block pitch advancement.

Shape mode emits blockers with quoted context and remediation options before advancing to readiness-check verdict.

## Pitfalls

- **Rule changes don't auto-update running agents** — must run `make install` to regenerate and reinstall
- **`{% include %}` paths** are relative to repo root; broken includes fail silently in some renderers — check `generate.sh` output
- **Never duplicate rules** across common fragment and individual template — add to common fragment, include once
- **Pi templates** — Pi harness generates from the same `shared/subagents/` tree as Claude; check `harnesses/pi/manifest.yaml` for any pi-specific overrides or additional templates
- **`dev-gate` is not a subagent template** — `dev-gate` refers to the orchestrator-invoked hook workflow (`phoenix-dev-gate.sh`), not an agent role with a `.md.j2` template; see `context/hooks.md` for gate mechanics
- **Trigger keywords refer to template wiring** — subagents.md covers how roles are assembled and baked into prompts; for what each role must/must-not do at runtime, see `context/rules-roles.md`

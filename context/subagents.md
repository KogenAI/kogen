# Subagents Domain — Subagent Templates + Roles

The subagents domain owns the `.md.j2` Jinja-style templates that `generate.sh` renders into per-harness agent prompt files. Each template uses `{% include %}` to inline rules, recipes, and common fragments — producing a self-contained system prompt baked at install time. Subagents never re-read rules at runtime; everything is pre-loaded into the rendered `.md`.

Two common fragments (`_phoenix_developer_common.md.j2`, `_static_developer_common.md.j2`) deduplicate shared backend/frontend developer rules.

## Components

| File                                                        | Purpose                                                             |
| ----------------------------------------------------------- | ------------------------------------------------------------------- |
| `shared/subagents/phoenix/planner-phoenix.md.j2`            | Phoenix planner — reads codebase, writes structured plan            |
| `shared/subagents/phoenix/developer-phoenix-backend.md.j2`  | Backend developer — schemas, contexts, migrations, Oban             |
| `shared/subagents/phoenix/developer-phoenix-frontend.md.j2` | Frontend developer — LiveView, HEEx, JS hooks, Tailwind             |
| `shared/subagents/phoenix/reviewer-phoenix.md.j2`           | Phoenix reviewer — quality, patterns, architecture                  |
| `shared/subagents/static/developer-static.md.j2`            | Static (Vite) site developer — vanilla by default, framework opt-in |
| `shared/subagents/static/planner-static.md.j2`              | Static (Vite) site planner — vanilla vs framework decision          |
| `shared/subagents/static/reviewer-static.md.j2`             | Static site reviewer                                                |
| `shared/subagents/shared/committer.md.j2`                   | Committer — analyzes diff, crafts why-focused commit message        |
| `shared/subagents/shared/context-curator.md.j2`             | Context curator — updates domain context files post-reviewer        |
| `shared/subagents/_phoenix_developer_common.md.j2`          | Shared rules fragment included by backend + frontend templates      |
| `shared/subagents/_static_developer_common.md.j2`           | Shared rules fragment included by all static developer templates    |

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
    developer-static.md.j2  ← vanilla Vite by default, framework opt-in
    planner-static.md.j2
    reviewer-static.md.j2
  shared/
    committer.md.j2
    context-curator.md.j2
```

Generated output lands in `templates/generated/<harness>/` then installed to `~/.claude/agents/` or equivalent.

## Integration Points

- **core**: `generate.sh` + `process_template.py` render these templates; output goes to `templates/generated/`
- **rules**: templates `{% include %}` rule files from `shared/rules/` — rule changes require re-running `make install`; behavioral rules for each role are documented in `context/rules-roles.md`; these templates are the wiring mechanism, not the rules themselves. **High-leverage pattern**: a single append-only edit to a shared rule like `shared/rules/stacks/phoenix/_core.md` reaches dev + planner + reviewer **simultaneously** via multiple include sites (e.g., `_phoenix_developer_common.md.j2:7`, `planner-phoenix.md.j2:29`, `reviewer-phoenix.md.j2:20`). When a fact or constraint applies across roles, default to appending to the shared stack `_core.md` rather than role-specific rules — one edit lands cross-role knowledge far more efficiently than three separate edits. **Backend/frontend-specific rule homes**: For Phoenix stack, `shared/rules/stacks/phoenix/testing-liveview.md` is included ONLY by `developer-phoenix-frontend.md.j2` and `reviewer-phoenix.md.j2` — the frontend-exclusive rule home. By contrast, `_core.md`, `developer.md`, and `testing.md` reach BOTH backend and frontend via `_phoenix_developer_common.md.j2`. When a rule must NOT reach backend developers (e.g., LiveView-specific patterns, HEEx idioms, Tailwind UI), append it to `testing-liveview.md`; when pruning backend-reachable files of frontend content, verify via the include graph which templates pull the rule-file being edited.
- **harnesses**: each harness may have harness-specific includes; claude harness renders phoenix + static; pi harness renders from the same `shared/subagents/` tree unless it has overrides in `harnesses/pi/`
- **scaffold**: `shared/apps/AGENTS-phoenix.md.j2` and `AGENTS-static.md.j2` are downstream AGENTS.md templates (separate from subagent templates here)
- **commands**: slash commands in `harnesses/claude/commands/` can spawn subagent swarms (e.g., `/poke-holes` spawns Explore agents to stress-test a pitch). Spawned subagents must satisfy role allowlist in `operator-subagent-allowlist.sh` (debug, shape, refactor, ops roles only).

## Rule Propagation & Two-Common-Fragment Pattern

**Developer rule consolidation via `_phoenix_developer_common.md.j2` and `_static_developer_common.md.j2`**: Both include `shared/rules/roles/developer.md` at line 5. This means a single edit to `developer.md` (e.g., adding a never-commit bullet) automatically propagates to all 3 developer variants — backend, frontend, and static — without any additional template edits. The two common fragments fan out to all instances:

- `_phoenix_developer_common.md.j2` → included by `developer-phoenix-backend.md.j2` and `developer-phoenix-frontend.md.j2`
- `_static_developer_common.md.j2` → included by `developer-static.md.j2`

**High-leverage pattern**: When a rule change must reach all developers (e.g., forbidding a commit mechanism), edit `shared/rules/roles/developer.md` once. When a rule must reach all agents in a stack (planners, devs, reviewers), edit `shared/rules/stacks/<stack>/_core.md` — it reaches via multiple include sites across multiple templates. One-source-of-truth holds across all baked variants: a rule file edit + `make install` propagates synchronously to all subagent prompts via the static include graph resolved at render time. **Planner templates** — `planner-static.md.j2` and `planner-phoenix.md.j2` are kept parallel at key structural lines (e.g., line 13 terse Step 0 pointer). When a planner rule changes, apply the SAME replacement to both templates. Audit with `diff` post-edit to confirm both got the update.

## Authoring Spine Rules (Shape/Refactor)

The `shared/prompt-fragments/_authoring-spine.txt` is included in both `shape.txt` and `refactor.txt` mode bodies. It encodes the investigative readiness loop that gates pitch advancement (Phase 0 context load → multi-turn investigation → readiness check before writing). Twelve core rules govern this loop:

**Rule A: Intent-guard before AskUserQuestion** — before emitting any question, check whether every proposed option preserves the pitch's core intent. Any option that would undo the primary claim or nullify the stated goal is FORBIDDEN; auto-narrow coverage instead of offering null options.

**Rule B: Plain-language discipline** — suppress internal shorthand (bare flags, internal probe names, unqualified identifiers, file paths, line numbers) in user-facing prose. Describe what something does. Exception: protected literals (`shared/rules/_core/output-style.md` § Verbatim) stay verbatim — code blocks, error strings, JSON field names, `MUST`/`NEVER`/`FORBIDDEN`, gate markers.

**Rule C: Command-level pairing auto-cover** — a claude-X launcher (claude-shape, etc.) always auto-includes its pi-X counterpart (pi-shape, etc.) as same-change coverage. Never ask "should I cover both harnesses?"; the answer is always yes.

**Rule D: Duplication-detection Phase-0 step** — during the blast-radius scan, grep for logic equivalent to the proposed change elsewhere in the codebase. If found, EXTRACTION (consolidating at the existing site) is the default proposal, never duplicate implementations. Auto-decide without asking.

**Rule E: Symptom-vs-target discipline** — when user names both a SYMPTOM (observed bad behavior) and a TARGET (thing to improve), the TARGET is the investigation subject. Probe the symptom ONCE to confirm origin, then pivot immediately to the target. Never let symptom-chasing displace target investigation.

**Rule F: Context-drift auto-cover** — when Phase 0 reveals a `context/*.md` file that disagrees with actual codebase state, auto-include that stale context file in the edit surface. Never ask whether to update it; including it is automatic.

**Rule G: Decompose-then-split** — when a problem is too large to build in one focused pass (spans multiple independent surfaces or requires prerequisites that don't exist yet), the shaper SPLITS it into N independently-buildable pitches ITSELF. It does NOT ask the user "should I split this?" or "how should I split this?". Splitting is an engineering-decomposition decision the shaper makes by reading code and dependency structure. Emit one chat line naming what was split: `Decomposed: extracted pitches <slug-1>, <slug-2> …`. This generalizes the dedup-extraction default (Rule D) from "extract on duplication" to "extract on scope". The ONLY split-related question that reaches the user is a genuine product fork the decomposition reveals.

**Rule H: Derive-and-write dependency edges** — when splitting, the shaper DERIVES the build-order dependencies by reading what each extracted pitch consumes that another produces, and WRITES them as `Blocks-on: <slug>` lines into each pitch's `## Dependencies` block. The dashboard topo-sorts these declared edges but performs zero inference of its own — an omitted edge silently mis-orders. Never ask "what depends on what?"; derive by reading code. The `## Dependencies` grammar is already shipped in `pitch-format-contract.md`. Every split MUST leave correct, parseable `## Dependencies` blocks behind. **Version/variant coverage**: when proposing a merge or consolidation of multi-version data sources (e.g., library API versions), analyze TOPIC COVERAGE ASYMMETRY — not just version numbers. Version N+k may add new topics AND drop existing ones. A blind version cutover that assumes monotonic growth will lose coverage. Example: `phoenix_live_view-1.1.28` adds components + js-interop but drops streams (vs 1.1.25). Merge strategy must analyze symmetric topic coverage, not assume "newer=better."

**Rule I: Ask-vs-decide classifier (Shape mode)** — ask the user ONLY when the answer changes what they experience or names something they own: UX copy/flow/behavior, product-intent forks (feature A vs feature B), or naming/identity they control. Test: "Does the answer change what the user experiences or names something the user owns?" If no → auto-decide from code + convention. Engineering-completeness decisions are NOT user decisions (install-guarantee, fail-closed-when-guaranteed, internal naming, split mechanics) → auto-decide and record as `Assumed: <dimension> = <default> (override if wrong)` in the end-summary.

**Rule J: Deferral-with-draft contract** — every deferral (any "deferred", "future work", "phase 2", "out of scope", "accepted risk") MUST be backed by a real `codegen/pitches/draft/<slug>.md` file. The pitch references the draft; a prose-only deferral is a blocker. Security/safety deferrals (auth, access control, secrets, data deletion) must additionally state the exposure assumption in the draft's rationale (e.g., "safe to defer only while the box is unreachable").

These rules are baked into the shape system prompt at install time. Changes to `_authoring-spine.txt` require `make install` to propagate.

## Deletion-Safety Blocker Classes (Shape)

Shape mode gates pitch readiness by scanning for three deletion-safety blocker classes:

- **Un-investigated rabbit holes** — a Rabbit holes entry or deferred unknown with no probe transcript and no draft-pitch backing. Every deferral must be backed by a `codegen/pitches/draft/<slug>.md` file (Rule J: deferral-with-draft contract). Security/safety-relevant deferrals must additionally state the exposure assumption they rest on. Prose-only deferrals are blockers, not resolutions.
- **Untraced edit surface / deletion claim** — a file named as an edit target or as deletable, with no provenance probe confirming its relevance.
- **Dangling cross-reference** — every `## Related pitches` entry must reference a file on disk in `codegen/pitches/{draft,ready,shipped}/`; unresolved references block pitch advancement.

Shape mode emits blockers with quoted context and remediation options before advancing to readiness-check verdict.

## Session-Log Header Requirements for Stack-Variant Templates

When a developer subagent template is stack-prefixed (e.g., `planner-phoenix`, `planner-static`, `developer-static`), any session-log Edit payload MUST include a stub `## <agent_type>-<stack> Section` header (e.g., `## planner-phoenix Section`). The `session-log-section-integrity.sh` hook bypass covers only the literal `AGENT_TYPE=planner` (non-stack), not variants. Stack-variant subagents must satisfy the normal header-present rule (hook lines 50–66): no bypasses apply.

## Subagent Template Include Placement & Edit Uniqueness

When editing subagent templates to add a new include line after an existing anchor (e.g., adding `{% include 'rules/shared/no-role-spawn.md' %}` after `output-style.md`), use a **two-line old_string** (anchor + the line immediately following it) to guarantee unique match per file. The anchor itself (`{% include 'rules/_core/output-style.md' %}`) appears identically across all 10 leaf-agent templates that include it — single-line matching would be ambiguous. Pairing anchor + context line disambiguates:

- Phoenix developers + planners/reviewers, plus static reviewers: anchor followed by another `{% include %}` line (e.g., `bash-discipline`, `cwd-discipline`)
- Static planner (`planner-static.md.j2`): anchor followed by a **blank line**, then prose starting with "First: …" — pair anchor + blank line to avoid matching prose content

Verified pattern: all 10 templates have `{% include 'rules/_core/output-style.md' %}` on a single line, followed by distinct next line (either another include or blank). Two-line pairing is sufficient for all files.

## Retrospective Scan Scope in Session Logs

The `subagent-retrospective-guard.sh` hook scans session-log `## Plan` blocks to extract `### What I Learned This Step` retrospective blocks for context-curator routing. **Scan stops at the first `^## ` H2 header** encountered after `## Plan` start. If the delegation prompt includes a fenced code block (e.g., `\`\`\`gate-json`, `\`\`\``) containing H2 markers like `## Files to touch`, those markers are treated as H2 boundaries and truncate the scan window. **Consequence**: retrospective blocks must precede ANY fenced `## `line, not just H2 headings outside fences. Move retrospective to the`## Plan` body proper (before the delegation-prompt fence).

## Pitfalls

- **Rule changes don't auto-update running agents** — must run `make install` to regenerate and reinstall
- **`{% include %}` paths** are relative to repo root; broken includes fail silently in some renderers — check `generate.sh` output
- **Never duplicate rules** across common fragment and individual template — add to common fragment, include once
- **Pi templates** — Pi harness generates from the same `shared/subagents/` tree as Claude; check `harnesses/pi/manifest.yaml` for any pi-specific overrides or additional templates
- **`dev-gate` is not a subagent template** — `dev-gate` refers to the orchestrator-invoked hook workflow (`phoenix-dev-gate.sh`), not an agent role with a `.md.j2` template; see `context/hooks.md` for gate mechanics
- **Trigger keywords refer to template wiring** — subagents.md covers how roles are assembled and baked into prompts; for what each role must/must-not do at runtime, see `context/rules-roles.md`
- **Role-def include gaps create invisible rule blindness** — audit of phoenix subagents (session 20260612_121603) revealed: `planner-phoenix.md.j2` does not include `generators.md` (phx.gen.live forbiddance rule invisible to planner); `reviewer-phoenix.md.j2` lacks `testing-liveview.md` (LiveView lifecycle checks missing); `manifest-external-resource.md` is included in zero role-defs (@external_resource cross-check invisible to all). When including stack rules in subagent templates, inventory all related rule files and verify each is explicitly included where relevant. A rule file in `shared/rules/stacks/phoenix/` not included in any role-def is a coverage gap. Fix requires: (1) edit the missing rule file (or move content), (2) add `{% include %}` to the role-def template, (3) run `make install` to regenerate + reinstall prompts.
- **Static planner places `output-style.md` at end of include block** — `planner-static.md.j2` includes `output-style.md` as the LAST rule include before prose content, followed by a blank line. This is intentional (recency-bias placement for output constraints in planner decision-making). The adjacency rule "new rule lands immediately after `output-style.md`" is still satisfied; static planners are structured differently than phoenix planners, but they still honor the include-order contract.

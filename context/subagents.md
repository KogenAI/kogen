# Subagents Domain — Subagent Templates + Roles

The subagents domain owns the `.md.j2` Jinja-style templates that `generate.sh` renders into per-harness agent prompt files. Each template uses `{% include %}` to inline rules, recipes, and common fragments — producing a self-contained system prompt baked at install time. Subagents never re-read rules at runtime; everything is pre-loaded into the rendered `.md`.

Two common fragments (`_phoenix_developer_common.md.j2`, `_static_developer_common.md.j2`) deduplicate shared backend/frontend developer rules.

## Components

| File                                                        | Purpose                                                             |
| ----------------------------------------------------------- | ------------------------------------------------------------------- |
| `shared/subagents/phoenix/developer-phoenix-backend.md.j2`  | Backend developer — schemas, contexts, migrations, Oban             |
| `shared/subagents/phoenix/developer-phoenix-frontend.md.j2` | Frontend developer — LiveView, HEEx, JS hooks, Tailwind             |
| `shared/subagents/phoenix/reviewer-phoenix.md.j2`           | Phoenix reviewer — quality, patterns, architecture                  |
| `shared/subagents/static/developer-static.md.j2`            | Static (Vite) site developer — vanilla by default, framework opt-in |
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
    developer-phoenix-backend.md.j2
    developer-phoenix-frontend.md.j2
    reviewer-phoenix.md.j2
  static/
    developer-static.md.j2  ← vanilla Vite by default, framework opt-in
    reviewer-static.md.j2
  shared/
    committer.md.j2
    context-curator.md.j2
```

Generated output lands in `templates/generated/<harness>/` then installed to `~/.claude/agents/` or equivalent.

## Integration Points

- **core**: `generate.sh` + `process_template.py` render these templates; output goes to `templates/generated/`
- **rules**: templates `{% include %}` rule files from `shared/rules/` — rule changes require re-running `make install`; behavioral rules for each role are documented in `context/rules-roles.md`; these templates are the wiring mechanism, not the rules themselves. **High-leverage pattern**: a single append-only edit to a shared rule like `shared/rules/stacks/phoenix/_core.md` reaches both developers + reviewer **simultaneously** via multiple include sites (e.g., `{% include 'rules/stacks/phoenix/_core.md' %}` in `_phoenix_developer_common.md.j2` — which backend and frontend both pull — and in `reviewer-phoenix.md.j2`). When a fact or constraint applies across roles, default to appending to the shared stack `_core.md` rather than role-specific rules — one edit lands cross-role knowledge far more efficiently than three separate edits. **Backend/frontend-specific rule homes**: For Phoenix stack, `shared/rules/stacks/phoenix/testing-liveview.md` is included ONLY by `developer-phoenix-frontend.md.j2` and `reviewer-phoenix.md.j2` — the frontend-exclusive rule home. By contrast, `_core.md`, `developer.md`, and `testing.md` reach BOTH backend and frontend via `_phoenix_developer_common.md.j2`. When a rule must NOT reach backend developers (e.g., LiveView-specific patterns, HEEx idioms, Tailwind UI), append it to `testing-liveview.md`; when pruning backend-reachable files of frontend content, verify via the include graph which templates pull the rule-file being edited.
- **harnesses**: each harness may have harness-specific includes; the claude harness renders phoenix + static from the `shared/subagents/` tree
- **frontmatter renders in every flavour** — the shared `{% if tool.yaml_frontmatter %}...{% endif %}` block in each `.md.j2` is rendered for claude (`generate.sh`'s `_generate_claude` passes `claude true` + `--config config.yaml`). The `tools:` line is authored ONCE, in claude vocabulary, and used verbatim.
- **scaffold**: `shared/apps/AGENTS-phoenix.md.j2` and `AGENTS-static.md.j2` are downstream AGENTS.md templates (separate from subagent templates here)
- **commands**: slash commands in `harnesses/claude/commands/` can spawn subagent swarms (e.g., `/poke-holes` spawns Explore agents to stress-test a pitch). Spawned subagents must satisfy role allowlist in `operator-subagent-allowlist.sh` (debug, shape, refactor, ops roles only).

## Eager-vs-Lazy Include Discipline

When a pattern applies to every invocation of a role in a stack (e.g., Tailwind always required for static reviews), eagerly include it in the role template. When a pattern applies only to specific tasks (e.g., Oban + Ecto.Multi rarely needed), keep it as a recipe the pitch names and the developer reads on demand. Example: `reviewer-static.md.j2` now eagerly includes vite.md + tailwind.md (mandatory); Oban/refactor/node patterns moved to recipes (task-triggered, forwarded by orchestrator on keyword match).

## Rule Propagation & Two-Common-Fragment Pattern

**Developer rule consolidation via `_phoenix_developer_common.md.j2` and `_static_developer_common.md.j2`**: Both include `shared/rules/roles/developer.md` via `{% include 'rules/roles/developer.md' %}`. This means a single edit to `developer.md` (e.g., adding a never-commit bullet) automatically propagates to all 3 developer variants — backend, frontend, and static — without any additional template edits. The two common fragments fan out to all instances:

- `_phoenix_developer_common.md.j2` → included by `developer-phoenix-backend.md.j2` and `developer-phoenix-frontend.md.j2`
- `_static_developer_common.md.j2` → included by `developer-static.md.j2`

**High-leverage pattern**: When a rule change must reach all developers (e.g., forbidding a commit mechanism), edit `shared/rules/roles/developer.md` once. When a rule must reach all agents in a stack (devs + reviewer), edit `shared/rules/stacks/<stack>/_core.md` — it reaches via multiple include sites across multiple templates. One-source-of-truth holds across all baked variants: a rule file edit + `make install` propagates synchronously to all subagent prompts via the static include graph resolved at render time. **Parallel-template discipline** — the per-stack leaf templates that play the same part (`developer-static.md.j2` vs `developer-phoenix-backend.md.j2`/`-frontend.md.j2`; `reviewer-static.md.j2` vs `reviewer-phoenix.md.j2`) are kept parallel at key structural lines. When a role-level rule changes, apply the SAME replacement to every template for that role. Audit with `diff` post-edit to confirm each got the update.

## Authoring Spine Rules (Shape/Refactor)

The `shared/prompt-fragments/_authoring-spine.txt` is included in both `shape.txt` and `refactor.txt` mode bodies. It encodes the investigative readiness loop that gates pitch advancement (Phase 0 context load → multi-turn investigation → readiness check before writing). Twelve core rules govern this loop:

**Rule A: Intent-guard before AskUserQuestion** — before emitting any question, check whether every proposed option preserves the pitch's core intent. Any option that would undo the primary claim or nullify the stated goal is FORBIDDEN; auto-narrow coverage instead of offering null options.

**Rule B: Plain-language discipline** — suppress internal shorthand (bare flags, internal probe names, unqualified identifiers, file paths, line numbers) in user-facing prose. Describe what something does. Exception: protected literals (`shared/rules/_core/output-style.md` § Verbatim) stay verbatim — code blocks, error strings, JSON field names, `MUST`/`NEVER`/`FORBIDDEN`, gate markers.

**Rule C: Command-level pairing auto-cover** — a claude-X launcher (claude-shape, etc.) auto-includes every same-change counterpart. Never ask whether to cover them; the answer is always yes.

**Rule D: Duplication-detection Phase-0 step** — during the blast-radius scan, grep for logic equivalent to the proposed change elsewhere in the codebase. If found, EXTRACTION (consolidating at the existing site) is the default proposal, never duplicate implementations. Auto-decide without asking.

**Rule E: Symptom-vs-target discipline** — when user names both a SYMPTOM (observed bad behavior) and a TARGET (thing to improve), the TARGET is the investigation subject. Probe the symptom ONCE to confirm origin, then pivot immediately to the target. Never let symptom-chasing displace target investigation.

**Rule F: Context-drift auto-cover** — when Phase 0 reveals a `context/*.md` file that disagrees with actual codebase state, auto-include that stale context file in the edit surface. Never ask whether to update it; including it is automatic.

**Rule G: Decompose-then-split** — when a problem is too large to build in one focused pass (spans multiple independent surfaces or requires prerequisites that don't exist yet), the shaper SPLITS it into N independently-buildable pitches ITSELF. It does NOT ask the user "should I split this?" or "how should I split this?". Splitting is an engineering-decomposition decision the shaper makes by reading code and dependency structure. Emit one chat line naming what was split: `Decomposed: extracted pitches <slug-1>, <slug-2> …`. This generalizes the dedup-extraction default (Rule D) from "extract on duplication" to "extract on scope". The ONLY split-related question that reaches the user is a genuine product fork the decomposition reveals. Before writing any file, rule G itself runs the one-clause test (rule H's outcome (e)): two pieces whose ONE PURPOSE fits a single why-led subject are one pitch, not a split — a `blocks_on: []` edge or a different invariant is not proof of independence. A surviving split records the two-clause verdict in each sibling's `split_subject:` frontmatter; `mix codegen.pitches.scope --check` fails a SUBSUMED pair (one's `scope:` a subset of the other's) recording neither.

**Rule H: Derive-and-write dependency edges** — when splitting, the shaper DERIVES the build-order dependencies by reading what each extracted pitch consumes that another produces, and WRITES them into each pitch's `blocks_on:` YAML frontmatter flow-list (e.g. `blocks_on: [other-slug]`). The dashboard topo-sorts these declared edges but performs zero inference of its own — an omitted edge silently mis-orders. Never ask "what depends on what?"; derive by reading code. **Dual-read**: pre-existing pitches with no frontmatter fall back to the legacy `Blocks-on: <slug>` / `## Dependencies` prose grammar shipped in `pitch-format-contract.md`. Every split MUST leave correct, parseable `blocks_on:` lists behind. **Version/variant coverage**: when proposing a merge or consolidation of multi-version data sources (e.g., library API versions), analyze TOPIC COVERAGE ASYMMETRY — not just version numbers. Version N+k may add new topics AND drop existing ones. A blind version cutover that assumes monotonic growth will lose coverage. Example: `phoenix_live_view-1.1.28` adds components + js-interop but drops streams (vs 1.1.25). Merge strategy must analyze symmetric topic coverage, not assume "newer=better."

**Rule I: Ask-vs-decide classifier (Shape mode)** — ask the user ONLY when the answer changes what they experience or names something they own: UX copy/flow/behavior, product-intent forks (feature A vs feature B), or naming/identity they control. Test: "Does the answer change what the user experiences or names something the user owns?" If no → auto-decide from code + convention. Engineering-completeness decisions are NOT user decisions (install-guarantee, fail-closed-when-guaranteed, internal naming, split mechanics) → auto-decide and record as `Assumed: <dimension> = <default> (override if wrong)` in the end-summary.

**Rule J: Deferral-with-draft contract** — every deferral (any "deferred", "future work", "phase 2", "out of scope", "accepted risk") MUST be backed by a real `codegen/pitches/draft/<slug>.md` file. The pitch references the draft; a prose-only deferral is a blocker. Security/safety deferrals (auth, access control, secrets, data deletion) must additionally state the exposure assumption in the draft's rationale (e.g., "safe to defer only while the box is unreachable"). **Same-motivation carve-out:** before minting a draft, classify the deferral — does it share the pitch's OWN core motivation/invariant (same reason-for-change), or is it a different failure that survives even when this pitch ships? Same motivation → Rabbit-hole/No-go prose in the parent pitch, no draft required. Different bet → still needs a draft.

These rules are baked into the shape system prompt at install time. Changes to `_authoring-spine.txt` require `make install` to propagate.

## Deletion-Safety Blocker Classes (Shape)

Shape mode gates pitch readiness by scanning for four deletion-safety blocker classes:

- **Un-investigated rabbit holes** — a Rabbit holes entry or deferred unknown with no probe transcript and no draft-pitch backing. Every deferral must be backed by a `codegen/pitches/draft/<slug>.md` file (Rule J: deferral-with-draft contract). Security/safety-relevant deferrals must additionally state the exposure assumption they rest on. Prose-only deferrals are blockers, not resolutions.
- **Untraced edit surface / deletion claim** — a file named as an edit target or as deletable, with no provenance probe confirming its relevance.
- **Dangling cross-reference** — every `## Related pitches` entry must reference a file on disk in `codegen/pitches/{draft,ready,shipped}/`; unresolved references block pitch advancement.
- **Missing bilateral handoff record** — a concrete, path-bearing deferral (names an affected repo-relative path) whose sibling `handoffs:` record is absent from either pitch's frontmatter, or whose owner `scope:` omits the path — see `context/pitch-lifecycle.md` § Frontmatter Schema. A prose-only pointer alone no longer clears this class once a path is named.

Shape mode emits blockers with quoted context and remediation options before advancing to readiness-check verdict.

## Session-Log Role Naming for Stack-Variant Templates

When a subagent template is stack-prefixed (e.g., `developer-phoenix-backend`, `developer-static`, `reviewer-phoenix`), it writes its cycle-log event via `codegen-log section <agent_type> --body @-` (positional role, taken literally from `AGENT_TYPE`/`CLAUDE_ROLE`, e.g. `developer-phoenix-backend`) — a `{"ev":"role","role":"developer-phoenix-backend",...}` JSONL event, NOT a markdown `## <role> Section` header (the log has no headers at all; see `shared/rules/_core/session-log.md`). `codegen-log` is the sole writer — no raw Edit path exists, so there is no bypass/no-bypass distinction to track per stack variant.

## Subagent Template Include Placement & Edit Uniqueness

When editing subagent templates to add a new include line after an existing anchor (e.g., adding a rule include after `output-style.md`), use a **two-line old_string** (anchor + the line immediately following it) so a scripted cross-file replacement lands on the intended site. The anchor itself (`{% include 'rules/_core/output-style.md' %}`) appears identically in every template that includes it — a single-line match tells you nothing about which template you are in.

Verified pattern (6 templates carry the anchor: both `_*_developer_common.md.j2` fragments, `reviewer-phoenix.md.j2`, `reviewer-static.md.j2`, `committer.md.j2`, `context-curator.md.j2`): all six have the anchor on a single line followed by `{% include 'rules/shared/no-role-spawn.md' %}`. The follow-line is UNIFORM across all six, so the two-line pair does not discriminate between templates. Uniqueness comes from the per-file edit itself (the anchor occurs once per file); a repo-wide replacement of the pair will hit all six, which is usually what you want when adding a rule to every leaf agent.

## Explicit Subagent Spawn Directives

Every spawn-prompt code fence in `shared/apps/AGENTS-{phoenix,static}.md.j2` must be preceded by a directive line naming the subagent type. Pattern: a line `**Spawn**: use subagent_type \`<token>\``immediately above the fenced delegation prompt, on its own line, OUTSIDE any Jinja conditional. This allows the orchestrator to declare`subagent_type`parameter to the Agent tool, preventing fallback-guessing from prompt-text heuristics. The directive satisfies`operator-subagent-allowlist.sh` gate (allowlisted tokens pass on first spawn; preventing churn from denied built-in agents).

**Committer spawn**: the deterministic `OrchestrationLoop` spawns the committer role directly as the loop's COMMITTED step (see `context/test-harness.md`) for every build. The `AGENTS-{phoenix,static}.md.j2` session-loop prose is a downstream human-driven interactive-session artifact, not a codegen build fallback (the former shared `_orch-committer.md.j2` include fragment was retired this cutover).

**Spawn directive placement**: The line is placed immediately ABOVE the opening `\`\`\`` fence of the delegation prompt, on its own line. It is NOT wrapped in Jinja conditionals (`{% if tool.name == 'claude' %}...{% endif %}`), so it renders identically in every harness variant.

## Retrospective Event Scope in Session Logs

Session logs are append-only JSONL, not markdown with H2 sections — there is no scan-window or header-boundary concept. The `role-retrospective-before-stop.sh` Stop hook (blocking) asserts, for the currently-stopping role, that the cycle log carries BOTH a non-empty `{"ev":"role","role":<role>,"body":<prose>}` event AND EITHER a `{"ev":"learned","role":<role>,"text":<t>}` event OR an explicit `{"ev":"no_learning","role":<role>,"text":<t>}` event (the legal exit for a turn that genuinely produced nothing to learn). Substance — not text length — is enforced at the writer: `codegen-log` refuses a whole-text placeholder or compliance-echo payload for `--learned`/`--no-learning`/section bodies (exit 2, nothing written), so presence of the event is sufficient once written. The compliant path is one call: `printf '%s' "$body" | codegen-log section <role> --learned "<text>" --slug <slug>` — see `shared/rules/_core/session-log.md` § Ownership and § Enforcement for the full CLI contract.

## Pitfalls

- **Rule changes don't auto-update running agents** — must run `make install` to regenerate and reinstall
- **`{% include %}` paths** are relative to repo root; broken includes fail silently in some renderers — check `generate.sh` output
- **Never duplicate rules** across common fragment and individual template — add to common fragment, include once
- **`dev-gate` is not a subagent template** — `dev-gate` refers to the gate step of the build cycle (owned unconditionally by the Elixir loop's `LoopGate`), not an agent role with a `.md.j2` template; see `context/hooks.md` for gate mechanics
- **Trigger keywords refer to template wiring** — subagents.md covers how roles are assembled and baked into prompts; for what each role must/must-not do at runtime, see `context/rules-roles.md`
- **Role-def include gaps create invisible rule blindness** — when including stack rules in subagent templates, inventory all related rule files and verify each is explicitly included where relevant. A rule file in `shared/rules/stacks/phoenix/` not included in any role-def is a coverage gap. Fix requires: (1) edit the missing rule file (or move content), (2) add `{% include %}` to the role-def template, (3) run `make install` to regenerate + reinstall prompts. (A prior instance of this gap — `generators.md`/`testing-liveview.md`/`manifest-external-resource.md` unreachable from the phoenix role-defs — was closed: `generators.md` and `manifest-external-resource.md` are included in `_phoenix_developer_common.md.j2` (so both backend and frontend see them), and `testing-liveview.md` in `developer-phoenix-frontend.md.j2` + `reviewer-phoenix.md.j2`.)
- **Removing config.yaml role breaks slow tests** — Silently passes `make test`, fails `make test-stacks`.
- **[shared] Delegation-prompt H2 promotion (FIXED)** — `## ` lines in delegation bodies are indented to `##` before writing to prevent rank-order corruption.

## Trigger Keywords

developer-phoenix-backend, developer-phoenix-frontend, developer-static, reviewer, committer, .md.j2 template, agent rendering, include-order contract, rule adjacency

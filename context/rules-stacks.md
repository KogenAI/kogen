# Rules Stacks Domain — Stack-Specific and Cross-Stack Rules

Stack-specific rules (Phoenix vs static sites) plus cross-stack shared rules (git safety, hook layering, config discipline). These layer on top of core and role rules to give stack-appropriate guidance to planners and developers.

## Components

| File / Dir                                        | Purpose                                                                                |
| ------------------------------------------------- | -------------------------------------------------------------------------------------- |
| `shared/rules/stacks/phoenix/_core.md`            | Phoenix stack fundamentals — Elixir/OTP patterns, LiveView basics                      |
| `shared/rules/stacks/phoenix/planner.md`          | Phoenix planner guidance — slice definitions, backend/frontend split                   |
| `shared/rules/stacks/phoenix/developer.md`        | Phoenix developer patterns — contexts, schemas, Oban, migrations                       |
| `shared/rules/stacks/phoenix/testing.md`          | Phoenix/ExUnit testing patterns                                                        |
| `shared/rules/stacks/phoenix/testing-liveview.md` | LiveView-specific test patterns                                                        |
| `shared/rules/stacks/phoenix/generators.md`       | Generator discipline — ALWAYS phx.gen.schema/auth, NEVER hand-write schemas/migrations |
| `shared/rules/stacks/static/`                     | Static site stack rules (mirrors phoenix structure)                                    |
| `shared/rules/shared/git-readonly.md`             | Git safety rules — never force-push, credential handling                               |
| `shared/rules/build-runtime/result-json.md`       | Result-JSON format for build-mode subagent output                                      |

## Key Paths

```
shared/rules/stacks/
  phoenix/
    _core.md
    planner.md
    developer.md
    testing.md
    testing-liveview.md
    generators.md
  static/
    *.md              ← mirrors phoenix structure for static stacks
shared/rules/shared/
  git-readonly.md
  (others)
shared/rules/build-runtime/
  result-json.md
```

## Integration Points

- **subagents**: stack-specific `.md.j2` templates `{% include %}` the matching stack rules — `developer-phoenix-backend.md.j2` includes phoenix rules; `developer-static.md.j2` includes static rules
- **hooks**: `gate-select.sh` picks the correct gate script (phoenix vs static) based on detected stack; parses ```gate-json block from `## Plan`— see`context/hooks.md`
- **rules-core**: stack rules are additive; core discipline rules (`context/rules-core.md`) apply regardless of stack
- **rules-roles**: stack rules extend role rules for stack-specific scenarios (role-level orchestrator rules were retired this cutover in favor of the deterministic `OrchestrationLoop`; see `context/test-harness.md`)

## Trigger Keywords

phoenix rules, static rules, git-readonly, result-json, LiveView patterns, ExUnit, Oban, migrations, static site stack

## Pitfalls

- **Phoenix and static rule files mirror each other in structure** — when adding a new rule category to one stack, evaluate whether the other stack needs an equivalent
- **`shared/rules/shared/`** is cross-stack — not phoenix-specific despite living alongside phoenix rules; applies to both harnesses
- **INCONCLUSIVE table** — the Phoenix INCONCLUSIVE classification table moved into the loop gate logic (`LoopGate.run_gate/2`) this cutover; the former shared/rules/stacks/phoenix/orchestrator.md and shared/rules/roles/orchestrator.md role-rule files no longer exist
- **Rule changes are not live** — must `make install` to propagate to running agents
- **`og:image` MUST mandate needs asset-availability gap** — static-site rules mandating `og:image` on every page create an implicit gap for asset-free new sites (no images added yet). Developer agents may invent a placeholder URL or silently omit. Tighten guidance to: "emit `og:image` only when a real image is available in the site's assets; omit rather than fabricate a placeholder." Forces graceful degradation over fabrication.

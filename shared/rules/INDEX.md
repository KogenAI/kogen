# Rules Index

Used by `/rule` for placement.

## Folder Layout

```
rules/
  STYLE_GUIDE.md            ← rule authoring style
  _core/                    ← loaded by every subagent
    output-style.md         caveman ultra
    bash-discipline.md      Bash + Read + token budget + ports
    session-log.md          file naming, skeleton, citations
  shared/                   ← cross-role primitives
    git-readonly.md              read-only git ops, workspace, credentials
    config-single-source.md      shell launcher + Elixir runner read same config keys
    operator-batch-divergence.md interactive vs batch flag divergence is intentional
    yq-null-safety.md            (.field // []) guard on every yq array op
    multi-repo-ordering.md       context → codegen → platform commit ordering
    hook-layering.md             one hook one concern; universal vs role-specific
    hook-test-coverage.md        ≥14 cases per guard, DENY + ALLOW paths
    nodejs-process-management.md process groups, SIGTERM/SIGKILL, detached spawn cleanup
    shell-script-discipline.md   shebang, set -euo pipefail, quoting, trap, exit codes, path derivation
    rule-file-organization.md    line caps, INDEX update, make install rebake contract
  roles/                    ← universal role rules
    orchestrator.md         delegation/gates/commit timing/user comms/deploy
    planner.md              recipe/usage rules/plan structure
    developer.md            workflow, completion, pre-completion
    reviewer.md             15-step process + ast-grep
    committer.md            commit message rules, multi-repo
    context-curator.md      routing learnings, write surface, stale-line preference
  stacks/
    phoenix/
      _core.md              idioms, Ecto, contexts, LiveView UI
      orchestrator.md       gate commands, INCONCLUSIVE, ext→agent, slice routing
      planner.md            dep scan, OTP convention
      developer.md          pre-completion greps, mix workflow, hot reload, cleanup, codegen
      reviewer.md           @spec/@type/~p/Gettext/github_workflows
      committer.md          .po/.pot translator note
      testing.md            CI authority, TDD, coverage, BDD, LLM partitions, backend
      testing-liveview.md   LiveView/HEEx/browser/SPA testing
    static/
      planner.md            substack detection, tailwind detect
      developer.md          output dir, build pipeline, npm, Tailwind v4 invariants
      reviewer.md           selector/a11y/asset/JS/responsive checks
      html.md               plain HTML stack
      hugo.md               Hugo quickref
      hugo-deep.md          Hugo deep (lazy-load, planner names on demand)
      vite.md               Vite + React
      tailwind.md           Tailwind v4
      assets.md             favicons, robots, og
      js.md                 inline-handler + overlay gotchas
  build-runtime/
    result-json.md          final JSON contract
```

## Role Ownership

| Mistake                           | Role            | File                                                 |
| --------------------------------- | --------------- | ---------------------------------------------------- |
| Orchestrator delegated wrong time | Orchestrator    | `roles/orchestrator.md`                              |
| Committer wrote wrong message     | Committer       | `roles/committer.md`                                 |
| Developer wrote wrong code        | Developer       | `roles/developer.md`                                 |
| Curator edited wrong path         | Context Curator | `roles/context-curator.md`                           |
| Gate misclassified                | Hook author     | `codegen/harnesses/claude/hooks/phoenix-dev-gate.sh` |
| CR missed issues                  | CR              | `roles/reviewer.md`                                  |
| Elixir style broken               | Developer       | `stacks/phoenix/developer.md`                        |
| CI broken                         | Developer       | `stacks/phoenix/testing.md`                          |

**Key principle**: if orchestrator made wrong call, rule goes on orchestrator — even if subagent executed action.

## Recency-Bias Placement

Anthropic long-context: Claude weights TOP (system prefix) + BOTTOM (recency) strongest. Middle suffers "lost in the middle." Apply within every rule file AND within Jinja include order.

Within file:

1. **Reference** (rarely violated): TOP — patterns, framework knowledge
2. **Situational**: MIDDLE — testing, server management, token budget
3. **Hard rules + most-violated**: BOTTOM — must-follow constraints, "Done when:" line LAST

Include order in `_*_developer_common.md.j2`: references first, situational middle, `_core/output-style.md` LAST.

## Adding New Rules

1. Check existing for overlap
2. Identify responsible role
3. Smallest appropriate file
4. Update INDEX.md only for new file/category
5. Follow STYLE_GUIDE.md

## Project-Specific Content Check

"Would this rule make sense word-for-word in a different project?" Yes → shared rule file. No → `PROJECT_CONTEXT.md`/`CLAUDE.md` only.

Signs of leakage: project names, repo names, sibling paths, app-specific module/table/env-var names, infra/vendor specifics.

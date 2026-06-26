# LLM Token Tuning — Per-Role Economics

Load only for cost-tuning sessions. Theory + mechanics → `claude-token-mechanics.md`.

## Subagent isolation

Confirmed by official docs: `Task` spawn does **not** inherit the orchestrator's `CLAUDE.md` or `@`-imports. Each subagent gets exactly its `~/.claude/agents/<role>.md` + tool schemas + the delegation prompt. This is by design ("Their work doesn't bloat your context"). `memory_tokens=0` in `/context` output for a subagent is correct, not a measurement artifact.

## Planner (1–3 turns, or 80+ turns on heavy-Read sessions)

Low turn count → cache write/read ratio near 1.0. Each turn loads large Read payloads into the suffix; next turn those reads are cached at 0.1×. **Less sensitive** to system prompt bloat; **more sensitive** to total prompt size approaching the 200k window. Heavy-Read planners (60+ Reads → 88 turns) shift into developer economics. (Example: an observed planner session ran 88 turns, 5.3M cumulative cache reads, 95.7k peak single-turn context.)

## Developer (8–30 turns, edit-test-edit)

Cache reads dominate. Hit ratio should be 0.85+. A 30k-token system prompt at 0.1× over 30 turns = ~900k cache reads. If caching breaks (invalidation, lookback miss), those 30 turns re-bill the prefix at 1.0× — roughly 9× more expensive. **Most sensitive** to system prompt size and to anything that invalidates the prefix mid-session.

## BuildWorker (Haiku, medium effort)

**Cache is the budget.** Anything that touches the stable prefix mid-build (tool definitions, system prompt, agent JSON, settings JSON, any consumer-injected system-prompt file) is effectively a deploy event: measure before/after via your platform's agent-measurement script and verify `total_cache_hit_ratio` in the project's daily stats table the next day. (Example: a platform provides an agent-measurement script + a daily-stats table.)

## Role → Model/Effort Reference

Full mapping from `templates/generator/config.yaml` (Claude harness):

| Role                       | Model  | Effort |
| -------------------------- | ------ | ------ |
| planner-phoenix            | opus   | high   |
| planner-static             | opus   | high   |
| developer-phoenix-backend  | sonnet | medium |
| developer-phoenix-frontend | sonnet | medium |
| developer-static           | sonnet | high   |
| reviewer-phoenix           | sonnet | medium |
| reviewer-static            | sonnet | medium |
| committer                  | haiku  | low    |
| context-curator            | haiku  | low    |
| build (orchestrator)       | sonnet | medium |
| inspector                  | sonnet | medium |
| debug                      | sonnet | medium |
| app_build                  | sonnet | medium |
| shape                      | opus   | high   |
| ops                        | opus   | high   |
| experiment                 | opus   | high   |

## Investigation Modes Are Pinned By Design

`shape`, `experiment`, and `ops` are pinned to opus/high because they drive architectural decisions and complex multi-file analysis — the cost premium is justified. `debug` = sonnet/medium is also intentional (diagnostic, not creative). Cost sweeps **MUST NOT** propose downgrading these roles. Any proposal to move investigation modes to sonnet or reduce effort is out of scope and should be rejected without further analysis.

## Why Shared-Prefix Rule Extraction Is A False Economy

Baked role prompts (subagent system prompts) are cached at 0.1× per spawn after the first write. Same-workspace sessions share the cache entry — meaning the large static prefix pays the write tax once and is re-read cheaply for every subsequent spawn in that workspace.

Therefore, "move `_core` rules to a shared prefix to save tokens" is a false economy: the tokens are already cached at 0.1× and the architectural cost (split rendering, cross-harness coordination, new install logic) is not recovered. This approach was evaluated and rejected; it is recorded here so no future cost sweep re-raises it.

# LLM Token Tuning — Per-Role Economics

Load only for cost-tuning sessions. Theory + mechanics → `claude-token-mechanics.md`.

## Subagent isolation

Confirmed by official docs: `Task` spawn does **not** inherit the orchestrator's `CLAUDE.md` or `@`-imports. Each subagent gets exactly its `~/.claude/agents/<role>.md` + tool schemas + the delegation prompt. This is by design ("Their work doesn't bloat your context"). `memory_tokens=0` in `/context` output for a subagent is correct, not a measurement artifact.

## Planner (1–3 turns, or 80+ turns on heavy-Read sessions)

Low turn count → cache write/read ratio near 1.0. Each turn loads large Read payloads into the suffix; next turn those reads are cached at 0.1×. **Less sensitive** to system prompt bloat; **more sensitive** to total prompt size approaching the 200k window. Heavy-Read planners (60+ Reads → 88 turns) shift into developer economics. (Example: an observed planner session ran 88 turns, 5.3M cumulative cache reads, 95.7k peak single-turn context.)

## Developer (8–30 turns, edit-test-edit)

Cache reads dominate. Hit ratio should be 0.85+. A 30k-token system prompt at 0.1× over 30 turns = ~900k cache reads. If caching breaks (invalidation, lookback miss), those 30 turns re-bill the prefix at 1.0× — roughly 9× more expensive. **Most sensitive** to system prompt size and to anything that invalidates the prefix mid-session.

## BuildWorker (Sonnet, up to 2h)

**Cache is the budget.** Anything that touches the stable prefix mid-build (tool definitions, system prompt, agent JSON, settings JSON, `PLATFORM_INFO.md`) is effectively a deploy event: measure before/after via your platform's agent-measurement script and verify `total_cache_hit_ratio` in the project's daily stats table the next day. (Example: a platform provides an agent-measurement script + a daily-stats table.)

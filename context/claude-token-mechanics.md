# LLM Token Mechanics & Prompt Caching

Reference for token counting, billing, and caching when running Claude Code via the Anthropic Messages API. Runtime module details and fleet observability procedures live in project-specific context files.

Numbers verified against https://platform.claude.com/docs/en/build-with-claude/prompt-caching and https://code.claude.com/docs/en/cli-reference.md on 2026-05-12; pricing changes — re-check before quoting externally.

## 1. The Four Token Counters

Every Messages API response includes a `usage` object. Fields are mutually exclusive — every input token lands in exactly one bucket.

| Field                         | What it counts                                    | Billing multiplier      |
| ----------------------------- | ------------------------------------------------- | ----------------------- |
| `input_tokens`                | Tokens after the last cache breakpoint (uncached) | 1.0×                    |
| `cache_creation_input_tokens` | Tokens written into a new cache entry             | 1.25× (5m) or 2.0× (1h) |
| `cache_read_input_tokens`     | Tokens retrieved from an existing cache entry     | 0.1×                    |
| `output_tokens`               | Tokens the model generated                        | model-specific          |

Total billable input = `input_tokens + cache_creation_input_tokens + cache_read_input_tokens`.

A cache read costs 10% of base input. A 5-minute write costs 125% — net-positive after a **single** subsequent hit (1.25 + 0.1 < 1.0 + 1.0). A 1-hour write costs 200%, breaking even after two hits.

### Pricing per million tokens

| Model             | Base input | 5m write | 1h write | Cache read | Output |
| ----------------- | ---------- | -------- | -------- | ---------- | ------ |
| Claude Opus 4.7   | $5         | $6.25    | $10      | $0.50      | $25    |
| Claude Sonnet 4.6 | $3         | $3.75    | $6       | $0.30      | $15    |
| Claude Haiku 4.5  | $1         | $1.25    | $2       | $0.10      | $5     |

## 2. Prompt Cache: TTLs & Breakpoints

The cache stores **prefixes**. Requests mark positions with `cache_control: {"type": "ephemeral"}` (5-minute TTL) or `{"type": "ephemeral", "ttl": "1h"}` (1-hour TTL). On the next request, the API hashes the prefix up to each marker; on hit, those tokens are billed at 0.1× and skipped during processing.

Key rules:

- **Max 4 breakpoints per request.** Automatic caching consumes one slot.
- **Ordering is fixed.** Prefix hierarchy: `tools → system → messages`. A breakpoint implicitly caches everything earlier.
- **Minimum cacheable prefix**: Opus 4.5+/Haiku 4.5 = 4096 tokens; Sonnet 4.6 = 1024; older Sonnet/Opus 4/4.1 = 1024. Below floor: caching silently skipped — both cache counters return 0.
- **Lookback window: 20 blocks.** Entries more than 20 content blocks behind the current breakpoint are invisible; add an explicit breakpoint to keep old entries findable.
- **TTLs refresh on hit.** A cache read resets the timer at 0.1× cost.
- **`ENABLE_PROMPT_CACHING_1H=1`**: extends server-side TTL from 5 min to 1 hour. Trade-off: 2.0× write cost but survives multi-minute idle gaps between chained workers on the same user request — typically worth it when workers hand off slowly. (Example: the consuming app's LLM backend sets this in its claude env prefix function to span chained worker handoffs.)

Claude Code uses **automatic caching**: a single top-level `cache_control` flag, and the API manages breakpoint position as the conversation grows. The large static prefix (system prompt + CLAUDE.md + tool schemas + agent files via `--agents`) is cached aggressively; each new turn extends the suffix.

## 3. Cache Invalidation Cascade

Prompt structure:

```
[ tools | system prompt | conversation history | tool results | new user msg ]
\_____________ stable prefix ____________/ \_____ growing suffix ____/
```

Modifying `tools` invalidates `system` and `messages` too. What busts cache:

- Editing agent files → `make install` regenerates `~/.claude/agents/*.md` → new `mtimes_hash` → in-memory cache miss → cache re-bake on next spawn.
- A consumer-injected system-prompt file edit → its content hash flips → system prompt changes → all active caches pay the write tax once.
- `CLAUDE.md` or `AGENTS.md` edit → same cascade as agent file edits.
- Settings or agents JSON key change → bundle-key mismatch → re-bake.

Each turn's incremental tool I/O lands in `input_tokens` (full price) on arrival, then folds into the cached prefix the next turn (assuming breakpoint advanced).

## 4. Per-Turn vs. Cumulative — A Critical Distinction

`cache_read_input_tokens` is a **per-turn snapshot**: the number of tokens the model read from cache on that single turn. It is bounded by the context window. Summing it across N turns yields **cumulative read-volume** — a billing dimension, not a memory dimension.

Example: a planner session (Opus, 88 turns). Peak single-turn context = 95.7k tokens — well under Opus's 200k window. Summing `cache_read_input_tokens` across all 88 turns yields 5.3M tokens. That 5.3M is the total tokens read from cache over the entire session; it does not mean 5.3M tokens were in context simultaneously.

The billing consequence is real: 5.3M cache reads × $0.50/M = $2.65 in cache-read charges alone. But no context-window overflow occurred — the 5.3M is a throughput number, not a size number.

## 5. Stream-JSON Token Reporting

When invoking `claude --print --output-format stream-json`, the `usage` field appears in two places:

- **`message_start` event**: initial counts for the turn (usually zeros or prior-turn state).
- **`message_delta` event**: cumulative token counts for the current turn, updated as streaming progresses.

Two distinct terminal events:

- **`{"type": "message_stop"}`** — API-level streaming terminal. Signals the model finished generating.
- **`{"type": "result", ...}`** — Claude Code CLI-level terminal. Carries `usage`, `cost_usd`, `num_turns`, `is_error`. This is what a usage-parser must read. Missing this event → parse error (Example: a project-provided usage parser returns `{:error, {:no_result, ...}}`).

Example `result` event shape (relevant fields):

```json
{
  "type": "result",
  "usage": {
    "input_tokens": 1240,
    "cache_creation_input_tokens": 28650,
    "cache_read_input_tokens": 0,
    "output_tokens": 312
  },
  "cost_usd": 0.094,
  "num_turns": 1,
  "is_error": false
}
```

## 6. `--exclude-dynamic-system-prompt-sections`

This flag moves per-machine sections (cwd, environment, git context) from the system prompt into the first user message — improving cache reuse across machines and users who share a stable system prompt. See https://code.claude.com/docs/en/cli-reference.md.

A worker that runs from `System.tmp_dir!()` (or equivalent neutral cwd) prevents hook pollution of `--print` output — same principle: keep per-machine noise out of the cacheable prefix. Adding `--exclude-dynamic-system-prompt-sections` further improves cache consistency across builds. (Example: the consuming app's build worker already runs from a neutral tmp dir; adding the flag to the stream command builder is a common pending optimization.)

Note: `--bare` is API SDK probe only — not for `claude --agent <name> --print` CLI.

## 7. Forbidden Flags

`--max-turns N` is **FORBIDDEN in ALL codegen invocations** — a turn cap kills agentic builds (bouncer returned empty at `--max-turns 1`). NEVER pass it. The codegen build chain does not pass `--max-turns` and no caller should add it.

`--max-budget-usd N` — permitted; threaded via `CODEGEN_BUILD_MAX_BUDGET_USD` into an explicit `--max-budget-usd=<n>` argv entry to `mix codegen.loop` (not `EXTRA_FLAGS`), and enforced between role invocations: once accumulated cross-role spend reaches the cap, the cycle aborts before the next role is invoked (the in-flight role always completes). Absent → no cap, unchanged behavior.

## 8. Context Window

200k base for all models. 1M extended context available via API parameter for Opus 4.7 and Sonnet 4.6 — no CLI flag exposes this. Cached tokens still count toward the window — caching does not raise the ceiling. (Most consuming apps do not enable 1M extended context.)

## 9. Cache Regression Signals

The hit ratio is:

```
cache_hit_ratio =
  cache_read_input_tokens
  ─────────────────────────────────────────────────────────────────
  cache_read_input_tokens + cache_creation_input_tokens + input_tokens
```

Healthy: 0.85–0.95 on warm builds, 0.4–0.6 on cold first turns. Project-specific drop threshold (Example: the consuming app defines a ≥10pp 7-day drop threshold in its LLM telemetry docs).

## 10. Per-Role Token Economics (merged from the former `claude-token-tuning.md`)

### Subagent isolation

Confirmed by official docs: `Task` spawn does **not** inherit the orchestrator's `CLAUDE.md` or
`@`-imports. Each subagent gets exactly its `~/.claude/agents/<role>.md` + tool schemas + the
delegation prompt ("Their work doesn't bloat your context"). `memory_tokens=0` in `/context` output for
a subagent is correct, not a measurement artifact.

### Planner (1–3 turns, or 80+ turns on heavy-Read sessions)

Low turn count → cache write/read ratio near 1.0. Each turn loads large Read payloads into the suffix;
next turn those reads are cached at 0.1×. **Less sensitive** to system prompt bloat; **more sensitive**
to total prompt size approaching the 200k window. Heavy-Read planners (60+ Reads → 88 turns) shift into
developer economics. (Example: an observed planner session ran 88 turns, 5.3M cumulative cache reads,
95.7k peak single-turn context — the same worked example as § 4 above, told from the tuning angle.)

### Developer (8–30 turns, edit-test-edit)

Cache reads dominate. Hit ratio should be 0.85+. A 30k-token system prompt at 0.1× over 30 turns = ~900k
cache reads. If caching breaks (invalidation, lookback miss), those 30 turns re-bill the prefix at 1.0×
— roughly 9× more expensive. **Most sensitive** to system prompt size and to anything that invalidates
the prefix mid-session.

### BuildWorker (Haiku, medium effort)

**Cache is the budget.** Anything that touches the stable prefix mid-build (tool definitions, system
prompt, agent JSON, settings JSON, any consumer-injected system-prompt file) is effectively a deploy
event: measure before/after via your platform's agent-measurement script and verify
`total_cache_hit_ratio` in the project's daily stats table the next day.

### Investigation Modes Are Pinned By Design

`shape`, `experiment`, `debug`, and `ops` are all pinned to opus/high because they drive architectural
decisions, complex multi-file analysis, and production-server operations — the cost premium is
justified. Cost sweeps **MUST NOT** propose downgrading these roles — see `context/role-config.md`
for the full role→model table and the `thinking_tokens` per-mode reasoning ceiling.

### Why Shared-Prefix Rule Extraction Is A False Economy

Baked role prompts (subagent system prompts) are cached at 0.1× per spawn after the first write.
Same-workspace sessions share the cache entry — the large static prefix pays the write tax once and is
re-read cheaply for every subsequent spawn in that workspace. Therefore, "move `_core` rules to a shared
prefix to save tokens" is a false economy: the tokens are already cached at 0.1× and the architectural
cost (split rendering, cross-harness coordination, new install logic) is not recovered. This approach
was evaluated and rejected; recorded here so no future cost sweep re-raises it.

## 11. Quick Diagnostics

Per-session forensics (thrash signals, subagent breakdown) — project provides an analyzer. (Example: the consuming app exposes a session-analysis mix task.)

Static prompt assembly size (system prompt + tools + agent files) — project provides a budget tool. (Example: the consuming app exposes a token-budget mix task.)

Aggregate cache hit ratio (last 14 days) — project-specific stats table:

```sql
SELECT day, harness, role, total_cache_hit_ratio
FROM llm_daily_stats
WHERE day > now() - interval '14 days'
ORDER BY day DESC, role;
```

Resident token cost per agent role at spawn — project provides a measurement script. (Example: `bin/measure-agents.sh --label pre-deploy-$(date +%Y%m%d)`.)

## Trigger Keywords

token mechanics, context window, prompt caching, billing, Read cost, auto-compact, /context load, transcript JSONL, resident token cost, cache hit rate, token budget thresholds, token tuning, budget optimization, cost per role, Opus vs Haiku, Read discipline vs Bash grep, split rendering cost, cross-harness coordination cost, rejected optimization, subagent isolation, memory_tokens

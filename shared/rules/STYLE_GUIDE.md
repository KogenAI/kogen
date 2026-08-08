# Rule Style Guide

## Token-Optimized Writing

Rules are loaded into LLM context windows. Every token counts. Write for machines that follow instructions, not humans that need persuading.

**Caveman ultra style** — see `shared/style-caveman-ultra.md` (canonical). Rules are read by agents, not humans.

**Compression principles:**

- Lead with the rule, not the rationale. Put "Why" on a separate line only when non-obvious
- One example per pattern (bad → good). Never three
- No preambles: "It's important to note that..." → just state the rule
- No restating: if a rule exists in a shared file, reference it — don't repeat it
- Tables over prose for structured data
- Inline short rules: `**Rule**: X` on one line, not a headed section
- Code blocks: minimal — show the pattern, not a full module
- Avoid "NEVER do X" + "ALWAYS do Y" when they say the same thing — pick one

**Compression targets:**

| Metric                       | Target            |
| ---------------------------- | ----------------- |
| Shared rules (loaded by all) | < 50 lines each   |
| Subagent rules               | < 150 lines each  |
| Orchestration rules          | < 150 lines each  |
| Examples per pattern         | 1 (bad/good pair) |
| Preamble before first rule   | 0-2 lines         |

File exceeds target → split or compress. Don't loosen the target.

**Enforcement**: `make prompt-size-budget` (component of `make test`) fails when a rule file or rendered agent prompt exceeds its committed ceiling in `templates/generator/prompt-budgets.txt` — this table is the TARGET new files should hit; the budget file is the ENFORCED ceiling, frozen at current measured size for files that pre-date this gate. One-way ratchet: once a `shared/rules/` fragment shrinks to at-or-under its STYLE_GUIDE-derived target (50/150 lines above), its enforced ceiling drops to that target too — a grandfathered row never lets a shrunk file silently regrow back toward its old, larger committed size. A file still over target keeps its grandfathered row untouched. The ceiling is operator-owned, not the writer's to move — a red verdict means shrink or evict, never raise. A red verdict routes to context-curator's retire/compact action.

**Cross-role deduplication:**

- If content is identical across 2+ files loaded by different roles → extract to a shared file
- If content is in a file already loaded by both roles → keep in one, remove from other
- Reference format: `**See**: filename.md § Section Name`

## Criticality Markers

Use sparingly — visual noise reduces readability. Do NOT add emojis to emphasize a rule you just wrote — if the rule needs emphasis, rewrite it more clearly.

- 🚨 **CRITICAL**: Overrides other guidance (max 2 per file)
- 🔥 **IMPORTANT**: Context-dependent rule
- ⚠️ **WARNING**: Caution but not blocking
- ✅/❌: Allowed/Forbidden commands or patterns

## Structure

- Start with actionable requirements, not anti-pattern stories
- Priority order: blocking first, quality second
- Group related rules, don't scatter across sections

## Cross-Role Contamination

Rules loaded by multiple roles must either:

1. Use role-agnostic commands, OR
2. Add explicit role labels: `**feature-developer only**: ...`

## Adding New Rules

1. Check existing rules for overlap first
2. Add to the smallest appropriate file
3. Update INDEX.md keyword index
4. Follow compression principles above

## Include Classification Test

An {% include %} belongs in an always-loaded role prompt only if every invocation of that role needs it; otherwise it is a recipe (on-demand) or dead.

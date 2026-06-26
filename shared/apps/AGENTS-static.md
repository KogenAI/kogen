# AGENTS.md — Static Sites

Orchestrator for static website build on the AI platform. Spawn subagents via subagent definitions to handle each phase.

→ See `codegen/rules/_core/output-style.md` for output-style rules.

## MANDATORY: Load Rules FIRST

**On EVERY session start, before any work:**

1. **READ** `codegen/rules/roles/orchestrator.md` at session start

Do NOT read PROJECT_CONTEXT.md, domain context files, or recipes — planner handles that. Delegate to planner immediately after creating the session log.

## Behavioral Rules

- **Surgical changes**: Make only changes required to fulfil request. Do not refactor, rename, or reformat code the request did not mention.

- **Goal-driven verification**: After implementing, verify the specific goal is satisfied — not just that code compiles and CI is green. Run targeted test exercising requested behavior; if no such test exists, write one.

- **Multiple interpretations**: If request has two or more plausible interpretations leading to materially different code changes, stop and return clarification request via result JSON rather than guessing.

- **Simplicity first**: Prefer vanilla Vite (no framework) unless the request explicitly calls for React/Vue/Svelte/component-based architecture.
- **Invisible discoverability is baseline craft**: Complete meta tags, valid JSON-LD structured data, and answer-first headings are applied default-on — like favicons and robots.txt — and are NOT suppressed by surgical/simplicity-first. They require no user signal to enable.

## Work Efficiently

- Use exact path from system prompt — don't resolve symlinks
- All tools are pre-installed — no `which` checks
- On change requests: read only files you need to change

## What You Never Do

- Edit `public/` (generated, gitignored)
- Use Tailwind CDN — always compiled Tailwind v4
- Add `tailwind.config.js` or `postcss.config.js` — Tailwind v4 doesn't need them
- Add "Powered by the AI harness" to user apps
- Run `npm run build`, `vite build`, or any build command
- Make git commits directly — always delegate to committer subagent
- Invent visible FAQ sections, comparison/decision tables, or rewrite authored copy unless the user signals findability intent (e.g. "get found", "SEO", "show up on Google/ChatGPT", "people should find us") — those are Layer B; invisible discoverability (meta, JSON-LD, headings) is Layer A and needs no signal

## Critical Rules

- `public/` is ALWAYS gitignored
- package.json MUST have both `"build"` and `"serve"` scripts
- `"serve"` script MUST end with `python3 -u -m http.server --directory public 0`
- `vite.config.js` MUST set `build: { outDir: "public" }`. Run `mise exec -- npm install` after adding deps.
- Commit subject MUST be ≤ 50 chars. Never prefix with scope tags — imperative mood, no trailing period.
- **Gumroad buy buttons**: load `codegen/recipes/gumroad-buy-button.md` and render buy-button `href` as literal string `GUMROAD_PLACEHOLDER_URL`.

## Session Logging

→ See `codegen/rules/_core/session-log.md` for format.

**WHERE**: `codegen/logging/$(date -u +%Y%m%d_%H%M%S)_session.md`

Each invocation creates NEW log file. Run `date -u +%Y%m%d_%H%M%S` via Bash for timestamp. Create BEFORE delegating to planner. After writing file, immediately stamp it:

```bash
{
  echo ""
  echo "## Version Stamp"
  echo ""
  echo "- harness: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "- context: $(git -C ./codegen/context rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "- codegen: $(git -C ./codegen/rules rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "- pi: $(pi --version 2>/dev/null || echo unknown)"

  echo "- stamped_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >> <SESSION_LOG>
```

```markdown
# Session Log

**Started**: $(date -u)
**Task**: [What you're doing]

## Version Stamp

- harness: <hash>
- context: <hash>
- codegen: <hash>
- pi: <version>

- stamped_at: <iso timestamp>

## Rules Loaded

- [x] codegen/PROJECT_CONTEXT.md
- [x] codegen/rules/roles/orchestrator.md

## Plan

⛔ ORCHESTRATOR: Do NOT write anything here. This section is filled in by the planner subagent ONLY.
Spawn the stack planner subagent — `planner-phoenix` (Phoenix) or `planner-static` (static) — now. NEVER spawn the built-in `Plan`. Do not write a plan. Do not write bullet points. Do not write phases.

## Delegation Timeline

| Time | Agent | Task | Result |
| ---- | ----- | ---- | ------ |

## Files Modified

- [ ] [list files as subagents modify them]
```

## Phase 0 — planner

**DO NOT write the plan yourself. ALWAYS spawn the planner-static subagent — no exceptions.**

Always spawn `planner-static`. It decides vanilla vs framework within Vite (vanilla by default; React/Vue/Svelte only when the plan calls for it).

**Spawn**: use subagent_type `planner-static`

```
You are the planner-static subagent.

APP PATH: <app_path>
SESSION LOG: <session_log_path>
TASK: <raw user request>

Your subagent rules are pre-loaded in your system prompt. Load only the conditional/domain files listed in your role definition's "Conditional Rules" / "Stack-Specific Rules" sections and any the orchestrator's prompt names.

Write the plan by editing the `## Plan` section of <session_log_path>.
**REQUIRED**: Append `## planner Section` at the end noting what you loaded and decided.

Never report a blocker — make the decision yourself and document under Assumptions.
Never write code — your job is the plan.
```

After delegating to planner, append row to `## Delegation Timeline` table in session log:
`| <time> | planner-static | Write plan | <result> |`

## Phase 1 — developer

**Spawn developer-static.** Relay the planner's developer delegation prompt verbatim — do NOT rebuild it or add steps.

**Spawn**: use subagent_type `developer-static`

```
You are the developer-static subagent.

APP PATH: <app_path>
SESSION LOG: <session_log_path>
TASK: <raw user request>

Your subagent rules are pre-loaded in your system prompt. Load only the conditional/domain files listed in your role definition's "Conditional Rules" / "Stack-Specific Rules" sections and any the orchestrator's prompt names. Implement the task.

**REQUIRED**: Append `## <agent-name> Section` to <session_log_path> when done.
```

After delegating, append row to `## Delegation Timeline`:
`| <time> | <agent-name> | Implement site | <result> |`

## Phase 2 — orchestrator build check

No Phase 2 delegation. After developer-static reports done, orchestrator runs `static-site-build-check.sh` deterministically with four checks:

1. `mise exec -- npm run build` — Vite always ships package.json.
2. `package.json` invariants — `scripts.build` and `scripts.serve` present, `scripts.serve` ends with `python3 -u -m http.server --directory public 0`.
3. Tailwind v4 config absence — neither `tailwind.config.js` nor `postcss.config.js` may exist at app root.
4. Tailwind v4 directives — no `@tailwind ` directive in any `*.css`.

Orchestrator verdict:

- `ALL CLEAR ✅` — proceed to Phase 3.
- `FAILED ❌ <reason>` — re-delegate to developer with failure reason. **Retry budget: 2 attempts maximum.**
- `INCONCLUSIVE ⚠️ <classification>` — look up classification in `codegen/rules/roles/orchestrator.md` and run the prescribed action.

## Phase 3 — reviewer-static

After orchestrator records `ALL CLEAR ✅`: **spawn reviewer-static immediately.**

**Spawn**: use subagent_type `reviewer-static`

```
You are the reviewer-static subagent.

APP PATH: <app_path>
SESSION LOG: <session_log_path>

Your subagent rules are pre-loaded in your system prompt. Load only the conditional/domain files listed in your role definition's "Conditional Rules" sections and any the orchestrator's prompt names.

**SCOPE — review only what changed**:
Read <session_log_path> and locate the `## Files Modified` section. That list
is the AUTHORITATIVE scope: read ONLY those files plus any test files that
exercise them. Do NOT Glob or Grep the rest of the codebase. If `## Files
Modified` is empty or missing, your verdict MUST be "QUALITY ISSUES FOUND ❌:
slice developer did not record modified files" — append that and stop.

**BOUNDARIES — READ CAREFULLY**:
- You are the reviewer-static ONLY. You do NOT spawn the committer or any other agent — that is the orchestrator's job after you return.
- Do NOT update the `## Delegation Timeline` table — the orchestrator will add the row after you return.
- Your ONLY file write is appending `## reviewer-static Section` to <session_log_path>.
- Bash is not available to you. Use Read to read files.

**REQUIRED — DO NOT SKIP**: Your absolute final action MUST be appending `## reviewer-static Section` to <session_log_path> using the Edit tool. First use Read to get the exact last line of the file. Then use Edit with:
- old_string: that exact last line
- new_string: that same line followed by the section content

The section must contain exactly:

## reviewer-static Section

**Verdict**: QUALITY APPROVED ✅  (or: QUALITY ISSUES FOUND ❌)

[your findings here]
```

After delegating to reviewer-static, append row to `## Delegation Timeline`:
`| <time> | reviewer-static | Review code quality | <result> |`

If issues found: delegate fixes to the developer whose files were flagged → re-verify → re-review.

## Phase 3.5 — context-curator

After reviewer-static approves: **spawn context-curator immediately.**

**Spawn**: use subagent_type `context-curator`

```
You are the context-curator subagent.

APP PATH: <app_path>
SESSION LOG: <session_log_path>

Your subagent rules are pre-loaded in your system prompt. Read the session log to identify what changed this cycle, then update the relevant context files.

**BOUNDARIES**:
- Your ONLY file writes are to `context/*.md` files and appending `## context-curator Section` to <session_log_path>.
- Do NOT spawn any other subagents.
- Do NOT update `## Delegation Timeline` — the orchestrator will add the row after you return.
- End your `## context-curator Section` with a line `Files edited: <space-separated repo-relative paths>` or `Files edited: none` — this is the durable intent record consumed by the `curator-learning-committed` gate.
- If a `context/*.md` edit would push the file over 40,960 bytes, compress a stale bullet, relocate a verbose example, or split to a new context file — never drop the learning.
```

After delegating to context-curator, append row to `## Delegation Timeline`:
`| <time> | context-curator | Update context files | <result> |`

## Phase 4 — committer

After context-curator completes: **spawn committer.**

**Spawn**: use subagent_type `committer`

```

You are the committer subagent.

APP PATH: <app_path>
TASK SUMMARY: <brief description of what was built and why — WHY only; never name files or say "staged" — the committer stages the whole cycle (`git add -A`) itself. NEVER include the gate command, test output, or CI status.>

```

After delegating to committer, append row to `## Delegation Timeline`:
`| <time> | committer | Commit changes | <result> |`

After committer confirms the commit: if this is a pitch-driven build and the pitch file is still in `codegen/pitches/ready/`, move it: `mv codegen/pitches/ready/<slug>.md codegen/pitches/shipped/<slug>.md` (plain `mv` — pitch files are untracked, NEVER `git mv`).

## Result Reporting (MANDATORY)

→ See `codegen/rules/build-runtime/result-json.md` for build result JSON contract.

Final message MUST contain exactly one fenced JSON block with build result and NOTHING after it:

```json
{ "status": "success" }
```

or, on failure:

```json
{ "status": "failed", "reason": "<short reason>" }
```

Rules:

- Block MUST be in a ``json fenced code block (lowercase `json` after the opening ``).
- Block MUST be the last thing in final message — no prose, no commit hashes, no farewells after closing ```.
- `status` is exactly `"success"` or `"failed"` (lowercase string).
- For failures, `reason` is single short sentence (under 200 chars).
- Emit at most ONE such JSON block. A second one anywhere in final message → build recorded as failed.

This block is parsed programmatically. If you omit it, emit invalid JSON, or include extra text after it, build is recorded as failed even if all work succeeded. Do NOT output it before committing.

`{"status":"success"}` requires ALL of:

1. Session log exists with all subagent sections
2. Build check passed (orchestrator ran `static-site-build-check.sh` → `ALL CLEAR ✅` in session log)

3. Quality approved (reviewer-static)
4. Git commit made

## Most-Violated Hard Rules (recap)

- NEVER `git commit` directly — always delegate to committer subagent
- NEVER edit `public/` — it is generated and gitignored
- NEVER use Tailwind CDN or add `tailwind.config.js` / `postcss.config.js` — Tailwind v4
- NEVER run `npm run build`, `vite build`, or any build command — build-check script handles it

- NEVER emit `{"status":"success"}` before committer confirms
- NEVER skip planner — static builds ALWAYS run the stack planner first
- NEVER skip reviewer — spawn reviewer-static after every `ALL CLEAR ✅`

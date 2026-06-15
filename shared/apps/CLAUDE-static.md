# AGENTS.md — Static Sites

Orchestrator for static website build on the AI platform. Spawn subagents via Agent tool to handle each phase.

@codegen/rules/\_core/output-style.md

## MANDATORY: Load Rules FIRST

Static builds skip planner. Orchestrator reads ONE thing only — the stack from `PROJECT_CONTEXT.md` — then creates session log and delegates to the matching developer-html/developer-hugo/developer-vite agent.

**READ** `codegen/PROJECT_CONTEXT.md` — extract `stack:` value only.

## Behavioral Rules

- **Surgical changes**: Make only changes required to fulfil request. Do not refactor, rename, or reformat code not mentioned.

- **Goal-driven verification**: After implementing, reload page and confirm specific element/text/behavior is present. Reading source is not enough.

- **Multiple interpretations**: Two or more plausible interpretations → stop and return clarification request via result JSON.

- **Simplicity first**: Prefer simplest HTML/CSS/JS solution. No extra frameworks, npm packages, or patterns unless request explicitly calls for them.

## Work Efficiently

- Use exact path from system prompt — don't resolve symlinks
- All tools are pre-installed — no `which` checks
- On change requests: read only files you need to change

## What You Never Do

- Edit `public/` (generated, gitignored)
- Use Tailwind CDN — always compiled Tailwind v4
- Add `tailwind.config.js` or `postcss.config.js` — Tailwind v4 doesn't need them
- Add "Powered by the AI harness" to user apps
- Run `npm run build`, `vite build`, `hugo`, or any build command
- Make git commits directly — always delegate to committer subagent

## Critical Rules

- `public/` is ALWAYS gitignored
- package.json MUST have both `"build"` and `"serve"` scripts
- `"serve"` script MUST end with `python3 -u -m http.server --directory public 0`
- **Vite only**: `vite.config.js` MUST set `build: { outDir: "public" }`. Run `mise exec -- npm install` after adding deps.
- Commit subject MUST be ≤ 50 chars. Never prefix with scope tags — imperative mood, no trailing period.
- **Gumroad buy buttons**: load `codegen/recipes/gumroad-buy-button.md` and render buy-button `href` as literal string `GUMROAD_PLACEHOLDER_URL`.

## Session Logging

@codegen/rules/\_core/session-log.md

**WHERE**: `codegen/logging/$(date -u +%Y%m%d_%H%M%S)_session.md`

Run `date -u +%Y%m%d_%H%M%S` via Bash for actual timestamp. Create BEFORE delegating. After writing file, immediately stamp it:

```bash
{
  echo ""
  echo "## Version Stamp"
  echo ""
  echo "- harness: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "- context: $(git -C ./codegen/context rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "- codegen: $(git -C ./codegen/rules rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "- claude: $(claude --version 2>/dev/null || echo unknown)"
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
- claude: <version>

- stamped_at: <iso timestamp>

## Rules Loaded

- [x] codegen/PROJECT_CONTEXT.md
- [x] codegen/rules/stacks/static/html.md
- [x] codegen/rules/stacks/static/tailwind.md
- [x] codegen/rules/stacks/static/js.md
- [x] codegen/rules/stacks/static/assets.md
- [x] codegen/rules/roles/committer.md

## Delegation Timeline

| Time | Agent | Task | Result |
| ---- | ----- | ---- | ------ |

## Files Modified

- [ ] [list files as you modify them]
```

## Phase 1 — developer-html/developer-hugo/developer-vite (stack-matched)

Static site builds skip planner and reviewer-static — flow is developer-html/developer-hugo/developer-vite → committer. A deterministic SubagentStop hook (`static-site-build-check.sh`) runs between developer and committer and blocks cycle on build/invariant failure.

**Before delegating**, orchestrator MUST pick the stack and pass it explicitly.

- If `PROJECT_CONTEXT.md` records a concrete stack, use it.
- If stack is **TBD** (first build), apply Stack Decision tree below. First match wins.

### Stack Decision — Which Stack to Use

```
1. User explicitly mentions React / Vue / Svelte / "framework" / "component" /
   "SPA" / "dashboard with live data" / "like a web app"
   → Vite + React (or Vue/Svelte if specified)
   → Agent: developer-vite

2. Visitors of the site WRITE data — not just the owner
   (user accounts, login, comments, user-generated content, forms that save
   data, bookings, e-commerce, dashboards with real data)
   → Phoenix — NOT a static site. Escalate or clarify, do not proceed.

3. User wants multiple distinct pages, a blog, or content in Markdown
   → Hugo + Tailwind
   → Agent: developer-hugo
   Trigger words (any one is enough): "blog", "posts", "articles",
   "multi-page", "pages" (plural), "About page", "Contact page",
   "Services page", "recipes", "portfolio with my projects",
   any combination of two or more named pages, "content in Markdown".

4. Everything else (single landing page, portfolio one-pager, marketing
   page, "website" with one scroll, "homepage", simple form)
   → Plain HTML + compiled Tailwind
   → Agent: developer-html
```

**Fuzzy-prompt examples (judgment calls):**

- "personal site for my photography" → multi-page → **developer-hugo**
- "recipe sharing site" → content-heavy multi-page → **developer-hugo**
- "portfolio with my projects" → multi-page unless explicit single-page → **developer-hugo**
- "React-flavored landing page" → user named a framework → **developer-vite**
- "simple landing page for a coffee shop" → single page → **developer-html**
- "marketing page for my SaaS" → single page → **developer-html**
- "interactive site with smooth animations" → vanilla JS fine → **developer-html**

**Never use Hugo for React apps.** Multi-page React → Vite + React Router. Hugo is for content-driven sites.

**`public/` is always gitignored** for all static types.

**Agent routing**: orchestrator picks agent by description match — Claude Code's routing picks the installed agent whose description matches the stack. Pass chosen stack in delegation prompt.

```
You are the <developer-html|developer-hugo|developer-vite> subagent.

APP PATH: <app_path>
SESSION LOG: <session_log_path>
TASK: <raw user request>

Your subagent rules are pre-loaded in your system prompt. Load only the conditional/domain files listed in your role definition's "Conditional Rules" / "Stack-Specific Rules" sections and any the orchestrator's prompt names. Implement the task.

**REQUIRED**: Append `## <agent-name> Section` to <session_log_path> when done.
```

After delegating, append row to `## Delegation Timeline`:
`| <time> | <agent-name> | Implement site | <result> |`

## Phase 2 — automatic build check

No Phase 2 delegation. After developer-html/developer-hugo/developer-vite reports done, the `static-site-build-check.sh` SubagentStop hook fires automatically and runs four deterministic checks:

1. `mise exec -- npm run build` (skipped when no `package.json` — Hugo case).
2. `package.json` invariants — `scripts.build` and `scripts.serve` present, `scripts.serve` ends with `python3 -u -m http.server --directory public 0`.
3. Tailwind v4 config absence — neither `tailwind.config.js` nor `postcss.config.js` may exist at app root.
4. Tailwind v4 directives — no `@tailwind ` directive in any `*.css`.

On failure hook emits `decision: block` — Claude Code re-spawns developer with failure reason. Iterate until dev reports done with no block envelope.

On success hook appends synthetic `## static-site-verifier Section` to active step log.

## Phase 3 — committer

After developer-html/developer-hugo/developer-vite's final SubagentStop emits no `block` envelope, proceed to commit.

**NEVER emit `{"status":"success"}` before committer confirms.** Order is strict: STEP 1 (committer) → STEP 2 (context update) → STEP 3 (build_result JSON).

### STEP 1 (MANDATORY): Spawn committer subagent

```
You are the committer subagent.

APP PATH: <app_path>
TASK SUMMARY: <brief description of what was built and why — WHY only; never name files or say "staged" — the committer stages the whole cycle (`git add -A`) itself. NEVER include the gate command, test output, or CI status.>
```

After delegating to committer, append row to `## Delegation Timeline`:
`| <time> | committer | Commit changes | <result> |`

After committer confirms the commit: if this is a pitch-driven build and the pitch file is still in `codegen/pitches/ready/`, move it: `mv codegen/pitches/ready/<slug>.md codegen/pitches/shipped/<slug>.md` (plain `mv` — pitch files are untracked, NEVER `git mv`).

### STEP 2: Update context files if needed

Update `codegen/PROJECT_CONTEXT.md` and relevant `context/*.md` domain files if structure or conventions changed.

### STEP 3: Output build_result JSON

## Result Reporting (MANDATORY)

@codegen/rules/build-runtime/result-json.md

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
- Block MUST be last thing in final message — no prose, no commit hashes, no farewells after closing ```.
- `status` is exactly `"success"` or `"failed"` (lowercase string).
- For failures, `reason` is single short sentence (under 200 chars).
- Emit at most ONE such JSON block. A second one anywhere → build recorded as failed.
- **MUST NOT be emitted before Phase 3 STEP 1 (committer) reports done.**

This block is parsed programmatically. Omitting it, invalid JSON, or extra text after it = build recorded as failed.

## Most-Violated Hard Rules (recap)

- NEVER `git commit` directly — always delegate to committer subagent
- NEVER edit `public/` — it is generated and gitignored
- NEVER use Tailwind CDN or add `tailwind.config.js` / `postcss.config.js` — Tailwind v4
- NEVER run `npm run build`, `vite build`, `hugo`, or any build command — hook handles it

- NEVER emit `{"status":"success"}` before committer confirms

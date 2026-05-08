---
description: Generate ElixirDrops post topic suggestions and write complete drop content
---

Generate 5-10 ElixirDrops topic suggestions from available recipes and Elixir/Phoenix patterns. When user selects topic, write complete drop content.

**STEP 1: Topic Suggestion Phase**

**EXECUTION CHECKLIST:**
□ 1. Plausible analytics screenshot — if user provided with command, proceed; otherwise request it
□ 2. Read ALL coding rules from `~/Areas/Optimum/context/rules/subagents/`
□ 3. Fetch `https://elixirdrops.net/index.md` for all published drop titles
□ 4. Check `./drops/` for existing drafts — recommend from those first before suggesting new topics
□ 4b. Check every existing draft for matching `_hook.md` — if missing, write hook too
□ 5. Analyze `~/Areas/Optimum/context/recipes/` for adaptable patterns
□ 6. Generate suggestions avoiding ALL redundancy
□ 7. User selects topic → create content using proper Elixir style
□ 8. Validate all code blocks — format with `mix format`, compile-check with `Code.string_to_quoted!/1` for illustrative snippets, run standalone blocks with `elixir /tmp/test.exs`
□ 9. Test code examples → save markdown to `./drops/`

**Content Discovery — MANDATORY DUPLICATION CHECK:**

1. Fetch COMPLETE drops index:

   ```
   WebFetch `https://elixirdrops.net/index.md`:
   "Extract COMPLETE list of ALL drop titles, one per line."
   ```

2. VERIFY you received ALL drops — response should contain 40+ titles. Fewer → fetch failed.

3. Create duplication avoidance list:
   - Existing published drops (from index.md)
   - Draft drops in `./drops/` (check `ls ./drops/*.md`)
   - Semantic variations (e.g., "Ecto.StaleEntryError" = "optimistic locking" = "race conditions in updates")

4. Cross-check semantically — don't just match keywords:
   - "Parameter validation" could overlap with "Safe URL params" or "Ecto changesets"
   - "String.to_atom" covers "atom exhaustion" AND "preventing atom attacks"

5. Cross-check EVERY suggestion against avoidance list. ANY overlap → REMOVE that suggestion.

6. Full content verification: `https://elixirdrops.net/d/{short_id}.md`

Do NOT present suggestions until verified ZERO duplication.

**Analytics Integration (MANDATORY FIRST STEP):**

- Request Plausible screenshot BEFORE generating ANY suggestions — not optional
- Analyze for high-performing patterns (low bounce rate, high time on page, deep scroll)
- Identify content gaps in popular topic areas
- Use popular drop patterns to inform suggestions

**High-Performing Patterns (from analytics):**

1. **Direct Technical Warning + Solution** (3,596 impressions):
   - Opening: "Stop using `X`" or "`X` can crash your entire BEAM VM"
   - Structure: Problem → Bad code (❌) → Good code (✅) → Why it works

2. **Performance Optimization with Concrete Benefits** (2,768 impressions):
   - Opening: "Database queries for X become performance bottlenecks fast"
   - Structure: Problem → ETS/caching solution → Impl → Pro tips

3. **Developer UX Improvements** (3,791 impressions):
   - Opening: "Use this LiveView hook to make X automatically Y"
   - Structure: Goal → Impl → JavaScript hook → Integration steps

4. **Workflow Optimization** (2,872 impressions):
   - Opening: "Don't regenerate your entire X for every change"
   - Structure: Current problem → Incremental approach → Impl → Benefits

5. **Hidden Feature Discovery** (6,664 impressions — TOP PERFORMER):
   - Opening: "Stop using `@impl true`" — direct instruction with authority
   - Structure: What not to do → What to do instead → Compiler benefits → Examples

**Opening Paragraph Formula:**

- Technical authority — direct instruction or warning
- Immediate value proposition
- NO fluff — jump straight into technical challenge

**First Code Block Requirements:**

- Show SOLUTION in first block — gets screenshotted for social media, MUST demonstrate key technique
- Visual contrast: ❌/✅ comparison when showing bad vs good (both in same block)
- Real-world context, not toy examples
- Progressive complexity: start simple, add sophistication
- Perfect comment alignment — count characters precisely, align ALL comments at same column

**Twitter Hook Style Guide:**

- 280 char limit — aim 240-250 max for buffer
- Clean and direct — state problem and solution
- Technical focus — lead with code/technical insight
- No marketing fluff — avoid "🧵 Thread", "👇", "Here's how"
- Factual tone — only use facts from the drop
- Concrete: "500 KB → 1 KB" not "99% reduction" without showing math
- Link at end: `https://elixirdrops.net/d/[id]`
- Count characters precisely — don't guess

**Preventing Twitter Auto-Link Detection**

Twitter converts `Module.function` patterns to clickable links (e.g., `File.read!/1` → link to `file.read`). Fix with Zero-Width Space (ZWSP, U+200B) after the dot:

```
❌ Wrong: File.read!/1 on a 2GB file = 2GB RAM
✅ Right: File​.read!/1 on a 2GB file = 2GB RAM (ZWSP after "File")
```

ALWAYS insert ZWSP after module name dot in Twitter hooks:

- `File​.read!/1`, `File​.stream!/1`
- `Enum​.map/2`, `Enum​.reduce/3`
- `Ecto​.Query`, `Phoenix​.LiveView`
- `String​.to_atom/1`, `GenServer​.call/3`

ZWSP character: `​` (invisible, select between backticks to copy)

**Rich Topic Sources:**

- MCP Tools: Tidewave tools in Claude Code, playground usage
- Phoenix/LiveView: Mixed-language flash messages, custom hooks, dropdown patterns
- Testing: Wallaby async patterns, umbrella test failures, sys.get/put_state in tests
- DB: Ecto.StaleEntryError solutions, enum translations, schema patterns
- Deployment: Fly.io configs, Docker patterns, env setup
- Email/Templates: MJML patterns, CSS inlining, template optimization
- Dev Workflow: Custom IEX, JS.exec server-side, feature toggles
- Integrations: GitHub Actions, webhook verification, file streaming

**Gap Analysis:**

- Security: webhook verification, parameter sanitization
- Error handling: StaleEntryError, GenServer crashes
- Email: MJML templates, notification patterns

**"Hidden Feature" Angle (High Engagement)**

Features that are:

- Built into frameworks but poorly documented
- Solve common problems but hard to discover
- Mentioned briefly in docs without examples
- Save significant debugging time

Examples:

- `Ecto.Changeset.optimistic_lock/3` — prevents race conditions, buried in changeset docs
- `:sys.get_state/1` — debug GenServers/LiveViews, mentioned in Erlang docs only
- `Phoenix.LiveView.assign_new/3` — conditional assigns, not in main guides
- `Ecto.Query.exclude/2` — remove query parts, rarely mentioned

Template: "[Framework] has a hidden feature that [solves problem]. It's been [where documented] for years, but most devs [what they do instead]. Here's how it works..."

Present each suggestion as:

- **Title**: Proposed drop title
- **Problem**: What it solves
- **Hook**: Engaging first code snippet concept

**STEP 2: Content Writing Phase (when user selects topic)**

Write complete drop content, save as markdown for copy/paste.

**Title**: 30-57 characters, action-oriented, sentence case, code in backticks.

Good:

- "Phoenix contexts should return tuples, not raise" (51 chars)
- "Stop using bang functions in Phoenix contexts" (46 chars)

Bad:

- "Stop using `create_user!` in Phoenix contexts - return `{:ok, result}` tuples instead" (87 chars — too long)

Body structure:

Opening paragraph: problem/teaser that works as Twitter copy.

```elixir
# First code snippet - MOST ENGAGING/CLICKABLE
# Gets screenshotted for social sharing
# Must be visually appealing and immediately valuable
```

Explanation of solution and why it works.

Optional additional snippets for edge cases.

**MANDATORY: Link to relevant official docs** — always end with markdown link to most relevant hexdocs page. Format: `[Module.function/arity docs](https://hexdocs.pm/...)`

4. **First Code Snippet** — make screenshot-worthy:
   - Show "before and after" or key transformation
   - Clear variable names and formatting
   - Just enough context to be self-explanatory
   - Focus on "aha moment"

5. **Quality Assurance**:
   - Format ALL code blocks with `mix format`
   - Validate all code blocks: (a) write to `/tmp/drop_N.exs`, run `mix format /tmp/drop_N.exs`, copy back; (b) run `elixir /tmp/drop_N.exs` for standalone blocks; (c) for illustrative snippets with app modules, verify syntax with `Code.string_to_quoted!(code)` via `elixir -e`. If Tidewave available via `mcp__tidewave__project_eval`, use it too.
   - Title SHORT (30-57 chars)
   - Solution is simplest that works
   - Verify ALL API/fn calls against actual docs — don't guess
   - No invented metrics — only performance numbers shown in drop content. Say "drops from 500 KB to 1 KB" not "99% reduction" without proof.
   - Ask user to review for hallucinations before claiming completion

6. **Code Formatting**:

   Markdown code blocks don't get auto-formatted by `mix format`. Workflow:

   ```bash
   echo 'def your_function...' > temp_format.exs
   mix format temp_format.exs
   # copy formatted code back to markdown
   rm temp_format.exs
   ```

   If `mix format` prompts for Hex installation and hangs: run `mix local.hex --force` first.

   `mix format` vs Tidewave:
   - `mix format` — reformats code (indentation, spacing, line breaks)
   - `mcp__tidewave__project_eval` — validates code compiles and runs

   Both required.

   Compile-time macros limitation — can't test `~p` or `~H` sigils in Tidewave eval context. Create `.exs` file and run with `mix run` instead.

   Formatting best practices:
   - Comments on separate lines above code, not inline
   - Each `|>` on its own line
   - Multiple blocks: separate temp files (temp_format1.exs, temp_format2.exs, etc.)
   - Comment alignment: count characters precisely, align ALL inline comments at same column

   Known `mix format` surprises:
   - `<%= expr %>` → `{expr}` inside `~H` sigils
   - Alignment spaces in `case` arms stripped
   - Multi-line fn calls reformatted when LHS + RHS exceeds line length
   - `do: bare_call` → `do: bare_call()` in single-line do expressions
   - Plug `@behaviour` modules need `import Plug.Conn`

7. **Final Output** — ALWAYS save as TWO markdown files (don't ask — just save). Delegate all file writes to `static-site-developer` — orchestrator hook blocks direct Write calls:
   - Drop content: `./drops/[topic_name]_drop.md`
   - Twitter hook: `./drops/[topic_name]_hook.md` — hook text only, ZWSP embedded for direct copy-paste
   - Twitter hook MUST only use facts stated in the drop — cross-check every claim

8. **Content Categories**:
   - Core Elixir: Pattern matching, data transformation, error handling
   - Phoenix/LiveView: Components, real-time features, form handling, testing
   - DB/Ecto: Query optimization, migrations, data relationships
   - Dev Workflow: Testing patterns, deployment, debugging, tooling
   - Performance: Profiling, optimization, memory management
   - Integration: APIs, external services, background jobs

9. **Recipe Transformation**:
   - Extract core problem and solution
   - Simplify to essential parts
   - Focus on one specific aspect
   - Turn detailed considerations into brief gotchas

**Critical Requirements:**

- Working code only — every example must compile and run
- Focused scope — one clear problem, one clear solution
- Practical value — must solve something devs actually encounter
- Flexible length — 150-word tip to full blog-post style

**Idiomatic Code — MANDATORY before writing ANY code:**

1. Read `~/Areas/Optimum/context/rules/subagents/elixir-code-generation.md`
2. Read `~/Areas/Optimum/context/rules/subagents/phoenix.md`
3. Read `~/Areas/Optimum/context/rules/subagents/testing.md`
4. Apply ALL rules to code examples

Key patterns:

- Add `import Ecto.Query` when using `from` query syntax
- Use `MyAppWeb.Endpoint.subscribe/1` for PubSub in LiveView, NOT `Phoenix.PubSub.subscribe/2`
- `cast_assoc` for user-submitted params (runs changeset, validates, handles deletes)
- `put_assoc` for trusted programmatic data (structs, bypasses validation)
- `on_replace:` option required on `has_many`/`many_to_many` when using `cast_assoc`

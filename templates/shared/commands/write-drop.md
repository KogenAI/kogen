---
description: Generate ElixirDrops post topic suggestions and write complete drop content
---

Generate 5-10 ElixirDrops post topic suggestions based on available recipes and current Elixir/Phoenix development patterns. When user selects a topic, write the complete drop content following established format and quality standards.

Process:

**STEP 1: Topic Suggestion Phase**

Generate 5-10 topic suggestions by:

- **Check existing drops**: Fetch `https://elixirdrops.net/index.md` to get all published drop titles and avoid duplicating topics
- **Read coding rules**: Review ALL files in `~/Areas/Optimum/context/rules/subagents/` for both coding standards AND potential drop topics from common patterns/anti-patterns
- Reviewing `~/Areas/Optimum/context/recipes/` for adaptable patterns
- Drawing from the user's "Future drops" list and development notes
- Identifying common Elixir/Phoenix pain points and solutions
- Looking for unique angles on established practices
- Focusing on problems with clear, testable code solutions

**EXECUTION CHECKLIST:**
□ 1. Plausible analytics screenshot (if user provided it with command, proceed; otherwise request it)
□ 2. Read ALL coding rules from `~/Areas/Optimum/context/rules/subagents/` directory
□ 3. Fetch `https://elixirdrops.net/index.md` for all published drop titles
□ 4. **Check `./drops/` for existing drafts** — if drafts exist, recommend from those first before suggesting new topics
□ 5. Analyze recipes for adaptable patterns
□ 6. Generate suggestions avoiding ALL redundancy
□ 7. User selects topic → create content using proper Elixir style
□ 8. **MANDATORY: Validate all code blocks using `mcp__tidewave__project_eval`**
□ 9. Test code examples → save markdown file to `./drops/` directory

**Content Discovery Steps (Using index.md):**

🚨 **CRITICAL - MANDATORY DUPLICATION CHECK (NO EXCEPTIONS):**

1. **Fetch the COMPLETE drops index**:

   ```
   Use WebFetch on `https://elixirdrops.net/index.md` with this EXACT prompt:
   "Extract COMPLETE list of ALL drop titles, one per line, so I can check for duplicates.
   Include every single drop listed in the index."
   ```

2. **VERIFY you received ALL drops**: The response should contain 40+ drop titles. If you get less, you FAILED the fetch.

3. **Create a duplication avoidance list**: Before generating ANY suggestions, write out the complete list of topics to avoid:
   - Existing published drops (from index.md)
   - Draft drops in `./drops/` directory (check `ls ./drops/*.md`)
   - Semantic variations (e.g., "Ecto.StaleEntryError" = "optimistic locking" = "race conditions in updates")

4. **Search for similar topics with semantic understanding:**
   - Don't just match keywords - understand the core problem/solution
   - A drop about "Parameter validation" could overlap with "Safe URL params" or "Ecto changesets"
   - A drop about "String.to_atom" covers "atom exhaustion" AND "preventing atom attacks"

5. **Cross-check EVERY suggestion against the avoidance list** - If ANY overlap exists, REMOVE that suggestion

6. **For full content verification**: Access individual drops via `https://elixirdrops.net/d/{short_id}.md`

7. **User feedback integration**: If user says "Did you check for redundant content?" - you FAILED and must start over

8. Cross-reference short_ids with Plausible analytics data to understand what formats work best

**BLOCKING RULE**: Do NOT present suggestions to the user until you have verified ZERO duplication against the complete index.

**Analytics Integration (MANDATORY FIRST STEP):**

- 🚨 **STOP: Request Plausible screenshot BEFORE generating ANY suggestions**
- This is not optional - suggestions without analytics data are guesses
- Analyze the provided statistics to understand high-performing content patterns
- Look for topics with high engagement (low bounce rate, high time on page, deep scroll)
- Identify content gaps in popular topic areas
- Consider user behavior patterns (what keeps people reading vs. what makes them leave)
- Use popular drop patterns to inform new topic suggestions

**🔥 HIGH-PERFORMING PATTERNS (Based on 2,700+ Impression Analytics)**

**CRITICAL SUCCESS FACTORS from top-performing drops:**

**1. Direct Technical Warning + Solution Pattern (3,596 impressions):**

- **Opening Style**: "Stop using `X`" or "`X` can crash your entire BEAM VM"
- **Hook**: Immediate security/stability concern with code comparison
- **Structure**: Problem statement → Bad code (❌) → Good code (✅) → Why it works
- **Examples**: String.to_atom/1 exhaustion, @impl true deprecation

**2. Performance Optimization with Concrete Benefits (2,768 impressions):**

- **Opening Style**: "Database queries for X become performance bottlenecks fast"
- **Hook**: Technical problem → specific solution with measurable improvement
- **Structure**: Problem → ETS/caching solution → Implementation → Pro tips
- **Key Words**: "microsecond lookups", "built into the BEAM", performance comparisons

**3. Developer UX Improvements (3,791 impressions):**

- **Opening Style**: "Use this LiveView hook to make X automatically Y"
- **Hook**: Immediate UX benefit with minimal code
- **Structure**: Goal → Implementation → JavaScript hook → Integration steps
- **Focus**: Small code changes with disproportionate UX impact

**4. Workflow Optimization (2,872 impressions):**

- **Opening Style**: "Don't regenerate your entire X for every change"
- **Hook**: Inefficient current approach → smarter incremental solution
- **Structure**: Current problem → Incremental approach → Implementation → Benefits
- **Appeal**: Saves developer time and system resources

**5. Hidden Feature Discovery (6,664 impressions - TOP PERFORMER):**

- **Opening Style**: "Stop using `@impl true`" - direct instruction with authority
- **Hook**: Common anti-pattern → better built-in alternative most don't know
- **Structure**: What not to do → What to do instead → Compiler benefits → Examples
- **Key**: Reveals overlooked framework features that improve code quality

**STRUCTURAL SUCCESS ELEMENTS:**

**Opening Paragraph Formula:**

- **Technical authority**: Direct instruction or warning
- **Immediate value proposition**: What problem this solves
- **Conversational expertise**: "Here's how we handle..." or "Use this..."
- **NO fluff**: Jump straight into the technical challenge

**First Code Block Requirements:**

- **🚨 CRITICAL: Show the solution in first block** - The first code block gets screenshotted for social media, so it MUST demonstrate the key technique/function, not just the problem
- **Visual contrast**: ❌/✅ comparison when showing bad vs good (both in same block)
- **Immediate understanding**: Code should be self-explanatory
- **Real-world context**: Not toy examples - actual implementation patterns
- **Progressive complexity**: Start simple, add sophistication
- **🚨 CRITICAL: Perfect comment alignment** - Within each function, align ALL comments at the exact same column position (count characters precisely, don't guess)

**Content Structure That Drives Engagement:**

- **Problem-first**: Technical pain point developers actually face
- **Solution-focused**: Concrete code that solves the problem
- **Authority-driven**: "Stop doing X" or "Here's how we handle Y"
- **Incremental reveal**: Basic solution → advanced considerations → pro tips

**Twitter Hook Style Guide:**

- **280 character limit** - URLs count toward the limit (~35 chars for elixirdrops.net links)
- **Aim for 240-250 characters max** - Leave buffer for engagement and readability
- **Clean and direct** - State the problem and solution clearly
- **Technical focus** - Lead with the code/technical insight
- **Minimal emojis** - Use sparingly, only when they add clarity
- **No marketing fluff** - Avoid "🧵 Thread", "👇", "Here's how", etc.
- **Factual tone** - Present information straightforwardly
- **Only use facts from the drop** - Don't invent performance numbers, percentages, or metrics not shown in the content
- **Concrete over abstract** - Say "500 KB → 1 KB" not "99% reduction" unless you show the math
- **Link at end** - Include full URL with https:// (e.g. `https://elixirdrops.net/d/[id]`)
- **Count characters precisely** - Don't guess, actually measure the hook length
- **Backticks are acceptable** - Twitter renders them as literal backtick characters, not code formatting, but they still signal "this is code" to readers. Use them when the tweet is short enough (under ~220 chars without the URL). Skip them if the tweet is already near the limit.

**🚨 CRITICAL: Preventing Twitter Auto-Link Detection**

Twitter automatically converts `Module.function` patterns into clickable links (e.g., `File.read!/1` becomes a link to `file.read`). This breaks the visual presentation of Elixir code.

**The Fix: Zero-Width Space (ZWSP) after the dot**

Insert the invisible Unicode character U+200B after the dot to break Twitter's URL pattern detection:

- **Character**: `​` (zero-width space - invisible but copy-pasteable)
- **Unicode**: U+200B
- **HTML entity**: `&#8203;`
- **Windows**: Alt+08203 (numpad)

**How to apply:**

```
❌ Wrong: File.read!/1 on a 2GB file = 2GB RAM
✅ Right: File​.read!/1 on a 2GB file = 2GB RAM (ZWSP after "File")
```

**MANDATORY for Twitter hooks**: When providing Twitter-ready text, ALWAYS insert ZWSP after the module name dot in patterns like:

- `File​.read!/1`, `File​.stream!/1`
- `Enum​.map/2`, `Enum​.reduce/3`
- `Ecto​.Query`, `Phoenix​.LiveView`
- `String​.to_atom/1`, `GenServer​.call/3`

**Copy this ZWSP character**: `​` (select between the backticks - it's invisible)

The ZWSP is invisible to readers but prevents Twitter from interpreting the text as a URL.

**Rich Topic Sources Available:**

- **MCP Tools Integration**: Tidewave tools in Claude Code, playground usage
- **Phoenix/LiveView**: Mixed-language flash messages, custom hooks, dropdown patterns
- **Testing**: Wallaby async patterns, umbrella test failures, sys.get/putstate in tests
- **Database**: Ecto.StaleEntryError solutions, enum translations, schema patterns
- **Deployment**: Fly.io configurations, Docker patterns, environment setup
- **Email/Templates**: MJML patterns, CSS inlining tricks, template optimization
- **Development Workflow**: Custom IEX, JS.exec server-side, feature toggles
- **Infrastructure**: FLAME scaling, microservices, database migrations
- **Integrations**: GitHub Actions, webhook verification, file streaming

**Gap Analysis Based on Current Drops:**

- Security patterns (missing: webhook verification, parameter sanitization)
- Error handling (missing: StaleEntryError, GenServer crashes)
- Email/Communication (missing: MJML templates, notification patterns)

**"Hidden Feature" Angle (High Engagement)**

Look for features that are:

- ✅ **Built into frameworks** but poorly documented
- ✅ **Solve common problems** but hard to discover
- ✅ **Mentioned briefly** in docs without examples
- ✅ **Save significant debugging time** when found

**Examples of "hidden" features that work well:**

- `Ecto.Changeset.optimistic_lock/3` - prevents race conditions, buried in changeset docs
- `:sys.get_state/1` - debug GenServers/LiveViews, mentioned in Erlang docs only
- `Phoenix.LiveView.assign_new/3` - conditional assigns, not in main guides
- `Ecto.Query.exclude/2` - remove query parts, rarely mentioned

**Template for hidden features:**
"[Framework] has a hidden feature that [solves problem]. It's been [where it's documented] for years, but most developers [what they do instead]. Here's how it works..."

Present each suggestion as:

- **Title**: Proposed drop title
- **Problem**: Brief description of what it solves
- **Hook**: The engaging first code snippet concept

**STEP 2: Content Writing Phase (when user selects topic)**

Write the complete drop content following the proven format, then save it as a markdown file in the project directory for easy copy/paste:

````
Title: **🚨 CRITICAL: Keep titles concise (30-57 characters)** - Action-oriented, sentence case, code in backticks

**Good examples:**
- "Phoenix contexts should return tuples, not raise" (51 chars) ✅
- "Stop using bang functions in Phoenix contexts" (46 chars) ✅
- "Pattern matching on `DateTime` for business logic" (50 chars) ✅

**Bad examples:**
- "Stop using `create_user!` in Phoenix contexts - return `{:ok, result}` tuples instead" (87 chars - WAY too long)
- "Use `GenServer.call/3` timeout instead of manual cleanup" (57 chars - borderline, could be shortened)

Body structure:

Opening paragraph: Problem/teaser that works as Twitter copy
(This becomes your social media post when sharing)

```elixir
# First code snippet - MOST ENGAGING/CLICKABLE
# This generates the screenshot for social sharing
# Make it visually appealing and immediately valuable
````

Explanation of the solution and why it works

Optional additional code snippets:

```elixir
# Additional examples, edge cases, or variations
```

**MANDATORY: Link to relevant official docs** — always end the drop with a markdown link to the most relevant hexdocs/official docs page (e.g. the specific module or section being discussed). Use the format: `[Module.function/arity docs](https://hexdocs.pm/...)`

```

```

4. **First Code Snippet Guidelines** - Make it screenshot-worthy:
   - Show the "before and after" or the key transformation
   - Use clear, readable variable names and formatting
   - Include just enough context to be self-explanatory
   - Make it visually appealing with good whitespace
   - Focus on the "aha moment" that makes people want to learn more

5. **Quality Assurance** - Test and refine:
   - **🚨 MANDATORY: Format ALL code blocks with `mix format`** (see step 6 for workflow)
   - **🚨 MANDATORY: Validate code compiles using `mcp__tidewave__project_eval`** - Test each code block individually. If Tidewave is unavailable, STOP and inform user.
   - Verify type definitions, function signatures, and syntax are valid
   - Check that the title is SHORT (30-57 characters)
   - Verify the solution is the simplest that works
   - Ensure the explanation adds context without being verbose
   - **Verify all API/function calls against actual documentation**:
     - Check Phoenix/LiveView docs for correct function signatures
     - Verify Ecto query syntax and required imports
     - Confirm GenServer/OTP patterns match official guides
     - Look up any library functions you're unsure about - DON'T GUESS
   - **No invented metrics or percentages**:
     - Only use performance numbers that appear in the drop content
     - Don't make up "90% faster" or "10x improvement" claims
     - If giving concrete numbers, show the calculation in the drop
     - Better to say "drops from 500 KB to 1 KB" than "99% reduction" without proof
   - **Ask user to review for hallucinations** - Before claiming completion, explicitly ask: "Any hallucinations or incorrect patterns?"

6. **Code Formatting** - Ensure proper Elixir formatting:

   **CRITICAL**: Markdown code blocks don't get auto-formatted by `mix format`. Use this workflow:

   ```bash
   # For each code block in your drop:
   # 1. Create temporary .exs file with the code
   echo 'def your_function...' > temp_format.exs

   # 2. Format with mix (use --check-formatted to avoid interactive prompts)
   mix format temp_format.exs

   # 3. Copy formatted code back to markdown
   # 4. Delete temporary file
   rm temp_format.exs
   ```

   **⚠️ WARNING**: Running `mix format` in a fresh environment may prompt for Hex installation and hang.
   If this happens, run `mix local.hex --force` first.

   **Note**: `mix format` and Tidewave serve different purposes:
   - `mix format` - Reformats code (indentation, spacing, line breaks)
   - `mcp__tidewave__project_eval` - Validates code compiles and runs correctly

   Both are required for quality drops.

   **⚠️ Compile-time macros limitation**: Some code can't be tested in Tidewave's eval context:
   - `~p` sigil (Phoenix verified routes) - requires compile-time module attributes
   - `~H` sigil (HEEx templates) - same limitation

   For these, create a test `.exs` file and run with `mix run`:

   ```elixir
   # test_drop_sigil.exs
   defmodule TestRoutes do
     use Phoenix.VerifiedRoutes,
       endpoint: MyAppWeb.Endpoint,
       router: MyAppWeb.Router

     def test_params do
       params = %{page: 1, sort: "name"}
       ~p"/users?#{params}"
     end
   end

   IO.puts(TestRoutes.test_params())
   ```

   Run: `mix run test_drop_sigil.exs`

   **Formatting Best Practices**:
   - **Comments**: Place on separate lines above code, not inline (better readability)
   - **Pipe formatting**: Each `|>` on its own line with proper indentation
   - **Consistent spacing**: Follow `mix format` output exactly
   - **Multiple blocks**: Create separate temp files (temp_format1.exs, temp_format2.exs, etc.)
   - **🚨 CRITICAL: Comment alignment** - Within each function, count characters precisely and align ALL inline comments at the exact same column position (don't guess - actually count!)

   **Why this matters**:
   - **First code block becomes the social media screenshot** - it must show the solution, not just the problem
   - Visual contrast (❌ vs ✅) in the same block creates immediate engagement
   - People scrolling social media need to see the value instantly
   - Proper formatting makes code more readable and professional
   - Consistent with Elixir community standards
   - Prevents formatting issues that distract from content

7. **Final Output** - Save as TWO separate markdown files:
   - **Drop content**: `./drops/[topic_name]_drop.md` — the full drop body
   - **Twitter hook**: `./drops/[topic_name]_hook.md` — the hook text only, ready to copy-paste
   - Use proper markdown formatting (no code block wrapping)
   - **MANDATORY: Twitter hook must only use facts stated in the drop** — cross-check every claim in the hook against the drop content before saving. See Twitter Hook Style Guide above for format requirements.

8. **Content Categories** - Focus on high-value topics:
   - **Core Elixir**: Pattern matching tricks, data transformation, error handling
   - **Phoenix/LiveView**: Components, real-time features, form handling, testing
   - **Database/Ecto**: Query optimization, migrations, data relationships
   - **Development Workflow**: Testing patterns, deployment, debugging, tooling
   - **Performance**: Profiling, optimization techniques, memory management
   - **Integration**: APIs, external services, background jobs

9. **Recipe Transformation Guidelines** - If adapting from recipes:
   - Extract the core problem and solution
   - Simplify the code example to the essential parts
   - Focus on one specific aspect rather than the complete implementation
   - Turn detailed considerations into brief gotchas or tips

10. **Testing Workflow Example**:

    Create a simple test script to validate your drop:

    ```elixir
    # test_drop.exs
    # Test your drop code here

    # Example: Testing a pattern matching solution
    defmodule DropTest do
      def test_pattern_matching do
        # Your drop's code example
        case {:ok, "result"} do
          {:ok, value} -> IO.puts("Success: #{value}")
          {:error, reason} -> IO.puts("Error: #{reason}")
        end
      end
    end

    DropTest.test_pattern_matching()
    IO.puts("✅ Drop code tested successfully!")
    ```

    Run with: `elixir test_drop.exs`

Critical Requirements:

- **Working code only** - Every code example must compile and run
- **Focused scope** - One clear problem, one clear solution
- **Practical value** - Must solve something developers actually encounter
- **Proper formatting** - Use ```elixir code blocks for syntax highlighting
- **Flexible length** - Can range from short 150-word tips to longer blog-post style content
- **Unique angle** - Don't duplicate existing drops without adding new value

Content Quality Standards:

- **Problem-first approach** - Start with the pain point, not the solution
- **Executable examples** - Code should work in a real Elixir environment
- **Idiomatic code** - MANDATORY: Before writing ANY code:
  1. **READ the actual coding rules** from `~/Areas/Optimum/context/rules/subagents/elixir-code-generation.md`
  2. **READ Phoenix patterns** from `~/Areas/Optimum/context/rules/subagents/phoenix.md`
  3. **READ testing patterns** from `~/Areas/Optimum/context/rules/subagents/testing.md`
  4. **APPLY all rules** found in these files to your code examples
  5. **VERIFY** that every code example follows the patterns from the rules
  - Put all code references (functions, modules, variables) in backticks
  - The rules contain specific formatting requirements, type safety patterns, and Phoenix conventions that MUST be followed
  - **🚨 CRITICAL: Add `import Ecto.Query`** when using `from` query syntax
  - **🚨 CRITICAL: Use `MyAppWeb.Endpoint.subscribe/1`** for PubSub in LiveView, NOT `Phoenix.PubSub.subscribe/2`
- **Context matters** - Explain why the solution works, not just how
- **Community focused** - Write for developers who will encounter this problem
- **Searchable titles** - Include relevant keywords developers would search for

This process creates valuable, discoverable content that helps the Elixir community solve real problems while building your reputation as a knowledgeable developer.

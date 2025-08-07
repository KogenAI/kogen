---
description: Generate ElixirDrops post topic suggestions and write complete drop content
---

Generate 5-10 ElixirDrops post topic suggestions based on available recipes and current Elixir/Phoenix development patterns. When user selects a topic, write the complete drop content following established format and quality standards.

Process:

**STEP 1: Topic Suggestion Phase**

Generate 5-10 topic suggestions by:

- **Check existing drops**: Use Tidewave MCP to query the database and avoid duplicating topics
- **Read coding rules**: Review ALL files in `./codegen/rules/` for both coding standards AND potential drop topics from common patterns/anti-patterns
- Reviewing `./codegen/recipes/` for adaptable patterns
- Drawing from the user's "Future drops" list and development notes
- Identifying common Elixir/Phoenix pain points and solutions
- Looking for unique angles on established practices
- Focusing on problems with clear, testable code solutions

**EXECUTION CHECKLIST:**
□ 1. Request Plausible analytics screenshot (MANDATORY FIRST STEP)
□ 2. Read ALL coding rules from `./codegen/rules/` directory
□ 3. Query database for existing drops comprehensively  
□ 4. Analyze recipes for adaptable patterns
□ 5. Generate suggestions avoiding ALL redundancy
□ 6. User selects topic → create content using proper Elixir style
□ 7. **MANDATORY: Validate all code blocks using `mcp__tidewave__project_eval`**
□ 8. Test code examples → save markdown file

**Database Integration Steps:**

1. **Check Tidewave MCP availability** - if not available, ask user to start Phoenix server
2. Query existing drops with: `mcp__tidewave__execute_sql_query`
3. **Search for similar titles/topics with multiple queries:**
   - `SELECT title FROM drops WHERE LOWER(title) LIKE '%keyword%'`
   - `SELECT title FROM drops WHERE LOWER(title) LIKE '%related_concept%'`
   - Check for semantic overlap, not just keyword matches
4. **Cross-check all variations** - A drop about "Parameter validation" could overlap with "Safe URL params" or "Ecto changesets"
5. Find related topics for inspiration: Look for gaps or complementary angles
6. **Semantic overlap check**: Don't just match keywords - check if the core problem/solution overlaps with existing content
7. Verify user hasn't already written about it: Check user_id in results
8. **User feedback integration**: If user says "Did you check for redundant content?" - you missed something
9. Cross-reference short_ids with Plausible analytics data to understand what formats work best

**Analytics Integration (MANDATORY FIRST STEP):**

- 🚨 **STOP: Request Plausible screenshot BEFORE generating ANY suggestions**
- This is not optional - suggestions without analytics data are guesses
- Analyze the provided statistics to understand high-performing content patterns
- Look for topics with high engagement (low bounce rate, high time on page, deep scroll)
- Identify content gaps in popular topic areas
- Consider user behavior patterns (what keeps people reading vs. what makes them leave)
- Use popular drop patterns to inform new topic suggestions

**Proven High-Performing Content Patterns (Based on Analytics + DB Analysis):**

**Short & Practical (High Engagement):**

- Problem → immediate solution → brief explanation format
- "Fixing X Error" titles perform exceptionally well (Wallaby session ID drop is top performer)
- Quick wins that save developers time (seed reproduction, config changes)

**Comprehensive Guides (Deep Engagement):**

- Multi-section tutorials with clear headings (## format) - use sentence case, not title case
- Step-by-step implementation with code examples
- "How to" topics with complete workflows (sitemap generation, testing patterns)

**Tool/Setup Content (High Traffic):**

- Developer workflow improvements (Cursor rules, Tidewave setup)
- CI/CD and automation topics consistently popular
- Version announcements and tool updates get reliable traffic

**Content Structure That Works:**

- Opening paragraph that immediately describes the pain point
- First code block shows the core solution or key example
- Additional sections for edge cases or advanced usage
- Pro tips or gotchas sections perform well
- External links for deeper reading add credibility

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

Present each suggestion as:

- **Title**: Proposed drop title
- **Problem**: Brief description of what it solves
- **Hook**: The engaging first code snippet concept

**STEP 2: Content Writing Phase (when user selects topic)**

Write the complete drop content following the proven format, then save it as a markdown file in the project directory for easy copy/paste:

````
Title: Action-oriented, 40-60 characters, sentence case, code in backticks (e.g., "Fixing Wallaby's invalid session ID error with `:sys.get_state`")

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

Optional: Links to docs, related patterns, or further reading

```

```

4. **First Code Snippet Guidelines** - Make it screenshot-worthy:

   - Show the "before and after" or the key transformation
   - Use clear, readable variable names and formatting
   - Include just enough context to be self-explanatory
   - Make it visually appealing with good whitespace
   - Focus on the "aha moment" that makes people want to learn more

5. **Quality Assurance** - Test and refine:

   - **MANDATORY: Validate all code blocks using `mcp__tidewave__project_eval`**
   - If Tidewave MCP is not available, ask the user to enable the MCP server first
   - Test each code block individually to ensure it compiles correctly
   - Verify type definitions, function signatures, and syntax are valid
   - Test edge cases and ensure the solution is robust
   - Check that the title is descriptive and searchable
   - Verify the solution is the simplest that works
   - Ensure the explanation adds context without being verbose

6. **Final Output** - Save as markdown file:

   - Use Write tool to save the content as `[topic_name]_drop.md` in the project directory
   - Use proper markdown formatting (no code block wrapping)
   - This avoids terminal formatting issues and makes copy/paste clean

7. **Content Categories** - Focus on high-value topics:

   - **Core Elixir**: Pattern matching tricks, data transformation, error handling
   - **Phoenix/LiveView**: Components, real-time features, form handling, testing
   - **Database/Ecto**: Query optimization, migrations, data relationships
   - **Development Workflow**: Testing patterns, deployment, debugging, tooling
   - **Performance**: Profiling, optimization techniques, memory management
   - **Integration**: APIs, external services, background jobs

8. **Recipe Transformation Guidelines** - If adapting from recipes:

   - Extract the core problem and solution
   - Simplify the code example to the essential parts
   - Focus on one specific aspect rather than the complete implementation
   - Turn detailed considerations into brief gotchas or tips

9. **Testing Workflow Example**:

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
- **Idiomatic code** - Follow the coding standards from the rules directory:
  - Use `refute condition` instead of `assert condition == false`
  - Never add catch-all fallback clauses - fail fast on unexpected input
  - Use proper `@impl Module.Name` instead of `@impl true`
  - Extract repeated types to module level as `@type`
  - Always alias used modules and use aliased names
  - Each pipe `|>` on its own line, starting with raw value/variable
  - Put all code references (functions, modules, variables) in backticks
- **Context matters** - Explain why the solution works, not just how
- **Community focused** - Write for developers who will encounter this problem
- **Searchable titles** - Include relevant keywords developers would search for

This process creates valuable, discoverable content that helps the Elixir community solve real problems while building your reputation as a knowledgeable developer.

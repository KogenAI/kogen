---
description: Research technical topics to make informed implementation decisions
---

**PURPOSE**: Gather comprehensive information about technical topics to help make informed decisions when multiple approaches or solutions are available.

When you need to research a technical topic, I will conduct parallel searches to gather information from multiple sources, analyze the findings, and present you with actionable options.

Process:

**STEP 1: Initial Analysis**

1. **Get current date**:

   - **CRITICAL**: First use Bash tool with `date` command to get the ACTUAL current date
   - **IMPORTANT**: The AI assistant does NOT know the current date - it MUST use the terminal output from `date` command
   - **Use the exact date from terminal output** in all searches to find recent information

2. **Parse the research request**:

   - Identify the core technical problem or decision
   - Extract key terms and technologies mentioned
   - Determine the context (testing, DB ownership, dependencies, etc.)
   - Note any specific constraints or requirements

3. **Formulate search strategy**:
   - Create 8-12 targeted search queries
   - Include official documentation searches
   - Add community solutions (Stack Overflow, GitHub issues)
   - Search for recent developments using current year from `date` command
   - Include framework-specific resources

**STEP 2: Parallel Research Execution**

**CRITICAL: PARALLEL SEARCH STRATEGY**

- **ALWAYS run ALL searches simultaneously** in a single message
- **NEVER run searches sequentially** - batch 8-12 searches together
- **Target different aspects**: official docs, issues, tutorials, best practices

**Example Parallel Search Batch for Async Testing Issues**:

```
WebSearch: "playwright phoenix_test async false database ownership [current year]"
WebSearch: "Ecto.Adapters.SQL.Sandbox ownership async testing elixir"
WebSearch: "phoenix test async: false when to use"
WebSearch: "wallaby phoenix concurrent test database issues"
WebSearch: "ExUnit async database conflicts solutions [current year]"
WebSearch: "phoenix_test vs wallaby async testing comparison"
WebSearch: "site:hexdocs.pm phoenix_test async configuration"
WebSearch: "site:github.com phoenix_test issues async database"
```

Note: Replace [current year] with actual year from `date` command output

**Search Categories to Cover**:

- Official documentation (hexdocs, official guides)
- GitHub issues and discussions
- Stack Overflow solutions
- Blog posts and tutorials (recent)
- Framework comparisons
- Migration guides
- Performance benchmarks
- Community best practices

**STEP 3: Information Synthesis**

Analyze gathered information for:

- **Root cause identification**: What's actually causing the problem
- **Multiple solution approaches**: Different ways to solve it
- **Trade-offs**: Performance, complexity, maintainability
- **Community consensus**: What experienced developers recommend
- **Recent developments**: New features or fixes that might help
- **Compatibility concerns**: Version requirements, breaking changes

**STEP 4: Option Presentation**

Present findings in this format:

## Research Summary: [Topic]

**Problem Context**:
[Brief description of the issue being researched]

**Root Cause Analysis**:
[What's actually happening and why]

## Option 1: [Solution Name]

**Approach**: [Brief description]
**Pros**:

- [Advantage 1]
- [Advantage 2]
  **Cons**:
- [Disadvantage 1]
- [Disadvantage 2]
  **Implementation**: [Code example or steps]

## Option 2: [Solution Name]

**Approach**: [Brief description]
**Pros**:

- [Advantage 1]
- [Advantage 2]
  **Cons**:
- [Disadvantage 1]
- [Disadvantage 2]
  **Implementation**: [Code example or steps]

## Option 3: [Solution Name]

[Same format as above]

## Recommendation

Based on your specific context with [relevant factors], I recommend **Option X** because:

- [Reason 1]
- [Reason 2]

**Quick Decision Matrix**:
| Factor | Option 1 | Option 2 | Option 3 |
|--------|----------|----------|----------|
| Complexity | Low | Medium | High |
| Performance | Good | Excellent | Good |
| Maintainability | High | Medium | Low |
| Community Support | Strong | Moderate | Limited |

**QUALITY CRITERIA**:

✅ **Good Research Output**:

- Multiple viable options with clear trade-offs
- Code examples or configuration snippets
- Recent information (within last year)
- Links to authoritative sources
- Clear recommendation based on context

❌ **Poor Research Output**:

- Single solution without alternatives
- Outdated information (>2 years old)
- No code examples
- Vague recommendations
- Missing trade-off analysis

**Common Research Topics**:

- Testing configuration (async, database ownership)
- Dependency updates and compatibility
- Performance optimization approaches
- Architecture decisions (monolith vs microservices)
- Framework selection (Phoenix vs alternatives)
- Database choices (PostgreSQL features, migrations)
- CI/CD pipeline optimization
- Security best practices
- Error handling strategies
- Deployment options

**IMPORTANT NOTES**:

- Focus on practical, implementable solutions
- Prioritize official documentation and recent sources
- Consider the specific project context (existing stack, team expertise)
- Include migration paths if changing from current approach
- Highlight any breaking changes or version requirements

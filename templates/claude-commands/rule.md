Analyze the current conversation context to understand the full lesson learned from this session, then add a comprehensive rule to the appropriate rule file in ./codegen/rules/.

Process:

1. **Extract conversation context** - Review the current session for relevant errors, solutions, code examples, and lessons learned
2. **Check existing rule files** - Read ./codegen/rules/ directory to understand current categories and existing rules
3. **Determine best location** - Choose which existing rule file fits best, or create a new file if needed (rare)
4. **Create comprehensive rule** - Combine the provided rule description with conversation context to create a detailed rule including:

   - Clear principle statement
   - Specific implementation details
   - Real code examples from the current session
   - Context about how the rule was discovered
   - Why this approach works better than alternatives

5. **Add to appropriate file** - Insert the rule following existing formatting patterns in the chosen rule file

The rule description argument can be brief (e.g., "PhoenixTest database conflicts", "research source code first") - the full context will be extracted from the current conversation including specific errors encountered, solutions found, and code examples used.

Rule files typically include:

- **workflow.md** - Process, CI/CD, testing workflow, time tracking
- **elixir-code-generation.md** - Code style, patterns, best practices, anti-patterns
- **phoenix.md** - LiveView patterns, routing, controllers, contexts
- **browser-testing-mandatory.md** - Browser testing requirements, Playwright usage
- **ui-implementation.md** - Frontend patterns, Figma integration, component design
- **git.md** - Version control practices, branching, commits

If no existing file fits the rule's category, create a new rule file with proper structure.

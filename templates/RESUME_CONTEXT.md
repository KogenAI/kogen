# Resuming: {{PLAN_TITLE}}

## Feature: {{FEATURE_NAME}}

- **Branch**: {{CURRENT_BRANCH}}
- **HEAD**: {{COMMIT_HASH}}

## Implementation Status

I've started implementing changes according to PLAN.md. Please review the current progress and help me continue the implementation.

## Git Status

```
{{GIT_STATUS}}
```

## Commit History

{{COMMIT_LOG}}

## Available Git Commands

I have access to git commands for detailed analysis:

- `git diff main..HEAD` - See all changes from main branch
- `git diff --staged` - See staged changes
- `git diff` - See working directory changes

Use these commands if you need to see specific changes, or ask me to run them for you.

## Environment

- **Server**: http://localhost:{{PORT}} (already started and ready)
- **Database (dev)**: bemeda_personal_dev{{PARTITION}}
- **Database (test)**: bemeda_personal_test{{PARTITION}}

## Tech Stack

- Phoenix LiveView with Elixir
- PostgreSQL with Ecto
- Tailwind CSS
- MCP Servers: Tidewave (Elixir tools) + Playwright (browser automation)

## Important Notes

- **Database**: Set up and seeded via `mix setup` during initialization
- **Testing**: The seeds file (`priv/repo/seeds.exs`) contains test users for login testing
- **MCP Tools**: Use Tidewave for Elixir/Phoenix analysis and Playwright for browser automation

## Development Workflow

**If the plan contains stages:**
1. **Implement one stage at a time** - Stop after completing each stage
2. **Write comprehensive tests** - Ensure all new code has proper test coverage
3. **Run CI checks** - Execute `make ci` and ensure all checks pass
4. **Wait for user review** - Pause for user to review code and commit before proceeding to next stage

This staged approach ensures code quality and allows for proper review at each milestone.

## Request

Please help me continue implementing this feature. Review PLAN.md and:

1. **Check Current Status**: Use git commands above to see what's been implemented
2. **Analyze Progress**: What has been completed so far?
3. **Follow PLAN.md**: Are we on track with the planned approach?
4. **Next Steps**: What should be implemented next?
5. **Code Quality**: Any improvements needed?

**If the plan has stages, follow the staged development workflow above.**

Ask me to run specific git commands or use MCP tools to analyze the current state.

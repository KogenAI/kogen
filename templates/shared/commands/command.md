---
description: Create a new Claude Code slash command
argument-hint: [/command-name]
---

Create new Claude Code slash command and add to templates directory.

Process:

1. **Parse command name** — extract from argument (e.g., `/do-something` → `do-something`)
2. **Ask for purpose** — what should command do and when would it be used
3. **Design workflow** — break down steps the command should execute
4. **Create frontmatter** — add `description` and `argument-hint` if command takes params
5. **Write instructions** — use actionable language without excessive documentation
6. **Save** — `./codegen/templates/shared/commands/{command-name}.md`

Format requirements:

- **Frontmatter** with `---` delimiters and `description` field
- **Optional argument-hint** if command takes params (e.g. `[message]`, `[feature name]`)
- **Concise description** in frontmatter (one line)
- **Direct instructions** — what the agent should do step by step
- **No excessive documentation** — focus on actionable steps
- **Follow existing patterns** — reference other commands for consistency

Usage examples:

- `/command /do-something` → creates `do-something.md`
- `/command /analyze-performance` → creates `analyze-performance.md`
- `/command /create-migration` → creates `create-migration.md`

Then ask user what functionality they want the new command to provide.

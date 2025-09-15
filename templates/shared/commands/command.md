---
description: Create a new Claude Code slash command
argument-hint: [/command-name]
---

Create a new Claude Code slash command following the official format and add it to the templates directory.

Process:

1. **Parse command name** - Extract command name from the argument (e.g., `/do-something` becomes `do-something`)
2. **Ask for command purpose** - Get user to describe what the command should do and when it would be used
3. **Design the command workflow** - Break down the steps the command should execute
4. **Create proper frontmatter** - Add `description` field and `argument-hint` if the command takes parameters
5. **Write direct instructions** - Use actionable language without excessive documentation formatting
6. **Save to templates** - Create the file as `/Users/almirsarajcic/Areas/Optimum/codegen/templates/shared/commands/{command-name}.md`

Command format requirements:

- **Frontmatter** with `---` delimiters and `description` field
- **Optional argument-hint** if command takes parameters (e.g. `[message]`, `[feature name]`)
- **Concise description** in frontmatter (one line)
- **Direct instructions** in body - what the assistant should do step by step
- **No excessive documentation** - focus on actionable steps, not explanations
- **Follow existing patterns** - reference other commands for consistency

The argument should be the slash command format (e.g., `/do-something`, `/analyze-performance`) which will be used to create the corresponding `.md` file.

Examples of usage:

- `/command /do-something` → creates `do-something.md`
- `/command /analyze-performance` → creates `analyze-performance.md`
- `/command /create-migration` → creates `create-migration.md`

Examples of good command purposes:

- Automate repetitive tasks
- Standardize complex workflows
- Create reusable patterns
- Generate boilerplate content
- Perform multi-step analysis

Then ask user what functionality they want the new command to provide.

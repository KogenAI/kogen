---
description: Create a new Claude Code slash command
argument-hint: [/command-name]
---

Create new Claude Code slash command.

Process:

1. **Parse command name** — extract from argument (e.g., `/do-something` → `do-something`)
2. **Ask for purpose** — what should command do and when would it be used
3. **Determine save location** — analyze purpose/name and recommend ONE of three paths:
   - **Project `./.claude/commands/{name}.md`** — if command depends on this project's context, codebase, or domain (e.g. `myproject-debug`, `blog-post` tied to example.com, project-specific debugging). Confirm with user.
   - **Shared `~/Areas/Optimum/codegen/harnesses/claude/commands/{name}.md`** — if command is generic and useful across all projects (e.g. `document`, `split`, `research`). Propagates via symlinks.
   - **User `~/.claude/commands/{name}.md`** — personal cross-project command that shouldn't propagate to teammates. Rare; only when user explicitly wants it.
     Heuristic signals:
   - Mentions project-specific paths/modules/products → project
   - References `PROJECT_CONTEXT.md` or project-specific tools → project
   - Generic workflow concept (research, plan, review, commit) → shared
   - Hot-take/style/personal-preference → user
     State recommendation + reasoning, ask user to confirm or override.
4. **Design workflow** — break down steps the command should execute
5. **Create frontmatter** — add `description` and `argument-hint` if command takes params
6. **Write instructions** — use actionable language without excessive documentation
7. **Save** to chosen path

Format requirements:

- **Frontmatter** with `---` delimiters and `description` field
- **Optional argument-hint** if command takes params (e.g. `[message]`, `[feature name]`)
- **Concise description** in frontmatter (one line)
- **Direct instructions** — what the agent should do step by step
- **No excessive documentation** — focus on actionable steps
- **Follow existing patterns** — reference other commands for consistency

Usage examples:

- `/command /do-something` → analyze, recommend location, save to chosen path
- `/command /analyze-performance` → likely shared (generic)
- `/command /myproject-debug` → likely project (name signals project-specific)

Then ask user what functionality they want the new command to provide.

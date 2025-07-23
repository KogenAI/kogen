# AGENTS.md

Guidance for AI assistants working with this repository.

## File Reference Convention

When you see `FILE: ./path/to/file.md` in any document, this indicates a loadable resource.

- These are NOT auto-loaded - you must decide whether and when to load them
- Load files only when their content is relevant to your current task
- Use your Read tool to load the file when needed

## Required Files

1. FILE: ./codegen/rules/RULES.md - **READ IMMEDIATELY**. Contains rule index.
2. FILE: ./codegen/PROJECT_CONTEXT.md - Read for any feature work. Has all project details.
3. FILE: ./codegen/CONTEXT.md - Only when resuming work.

## Rule Loading by Session Type

**Planning**: Load workflow.md, planning.md, [project-specific rules based on tech stack]
**Implementation**: Load workflow.md, [project-specific rules based on tech stack]
**Bug Fix**: Load workflow.md, regression-testing.md, [project-specific rules]
**Feature-specific**: figma.md (if "figma"), i18n.md (if "translation"), git.md (if "git")

## Key Reminders

- Run appropriate CI command before claiming completion
- Follow project-specific patterns and conventions
- Fix all linting warnings - no exceptions

PROJECT_CONTEXT.md has everything else. Focus on loading the right rules.

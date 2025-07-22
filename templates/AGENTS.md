# AGENTS.md

## File Reference Convention

Files are referenced as `FILE: path/to/file.md` to indicate loadable resources.
These are NOT auto-loaded - load only when relevant to the current task.

FILE: ./codegen/rules/RULES.md - read immediately - CRITICAL
Load referenced files from rules/ only when relevant to current task.

FILE: ./codegen/PROJECT_CONTEXT.md - project architecture reference
FILE: ./codegen/CONTEXT.md - current implementation status (if exists)

## CRITICAL RULES

See rules in RULES.md for mandatory development practices:

- Autonomous work requirements
- Testing protocols
- Completion verification

Load rules based on current task context.

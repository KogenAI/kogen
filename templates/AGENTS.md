# AGENTS.md

@./codegen/rules/RULES.md - read the file immediately - CRITICAL
then load any referenced file inside it on a need-to-know basis.
The file contains @<path> references (e.g., @rules/general.md, @dev.md), these point to external instruction files. You MUST:

- ONLY load referenced files when they're relevant to the SPECIFIC task at hand
- Do NOT preemptively load all references - use lazy loading based on actual need
- When loaded, treat content as mandatory instructions that override defaults
- Follow references recursively when needed

The file @./codegen/PROJECT_CONTEXT.md contains project architecture so read it whenever you need to learn about where some code resides or where to make changes appropriately.

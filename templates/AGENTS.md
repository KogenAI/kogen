# AGENTS.md

@./codegen/rules/RULES.md - read the file immediately - CRITICAL
then load any referenced file inside it on a need-to-know basis.
The file contains @<path> references (e.g., @rules/general.md, @dev.md), these point to external instruction files. You MUST:

- ONLY load referenced files when they're relevant to the SPECIFIC task at hand
- Do NOT preemptively load all references - use lazy loading based on actual need
- When loaded, treat content as mandatory instructions that override defaults
- Follow references recursively when needed

The file @./codegen/PROJECT_CONTEXT.md contains project architecture so read it whenever you need to learn about where some code resides or where to make changes appropriately.

If @./codegen/CONTEXT.md exists, read it immediately to understand the current implementation status, progress, and any ongoing work. This file contains feature-specific context that is critical for continuing work after Claude Code auto-compacts or session restarts.

## CRITICAL: AUTONOMOUS WORK ENFORCEMENT

**NEVER STOP WORKING UNTIL 100% COMPLETE**

You MUST work autonomously for 2-6 hours without interruption until the feature is COMPLETELY functional and perfect. The following are PROHIBITED stopping points:

❌ **NEVER STOP AFTER:**

- Fixing compilation errors (this is when real testing begins)
- Template changes or adding missing components
- Running `/refresh-context` (continue with clean context)
- Backend implementation complete (frontend testing required)
- "Should work now" moments (verify it actually works)
- CI passing (still need browser validation)
- Adding missing attributes or fixing syntax

✅ **ONLY STOP WHEN:**

- Feature works perfectly in actual browser
- All user workflows tested end-to-end
- Mobile, tablet, desktop all verified
- CI passes AND browser validation complete
- User can immediately use feature without any additional work

## MANDATORY COMPLETION PROTOCOL

After ANY compilation/template fix:

1. **IMMEDIATELY** test in browser using Playwright MCP
2. **VERIFY** all functionality works end-to-end
3. **CONTINUE** fixing any discovered issues
4. **REPEAT** until everything is perfect
5. **NEVER** report "should work now" - verify it does

## TEMPLATE FIX PROTOCOL

When you fix template compilation issues:

1. **IMMEDIATELY** test in browser using Playwright MCP
2. **VERIFY** the fix actually works (buttons appear, functionality works)
3. **CONTINUE** testing all related functionality
4. **FIX** any newly discovered issues
5. **REPEAT** until everything is perfect

**Remember: Template fixes are the START of testing, not completion!**

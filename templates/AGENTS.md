# AGENTS.md

Guidance for AI assistants working with this Phoenix LiveView repository.

## File Reference Convention

When you see `FILE: ./path/to/file.md` in any document, this indicates a loadable resource.

- These are NOT auto-loaded - you must decide whether and when to load them
- Load files only when their content is relevant to your current task
- Use your Read tool to load the file when needed

## Required Files

1. FILE: ./codegen/rules/RULES.md - **READ IMMEDIATELY**. Contains rule index.
2. FILE: ./codegen/PROJECT_CONTEXT.md - Read for any feature work. Has all project details.
3. FILE: ./codegen/FIGMA_MAP.md - **CHECK CONTEXT.md FIRST** - Only read if Figma work is pending.
4. FILE: ./codegen/CONTEXT.md - **ALWAYS READ WHEN RESUMING** to determine current stage.

## Rule Loading by Session Type

**CRITICAL**: These are MANDATORY, not optional. Load ALL listed rules for your session type IMMEDIATELY.

### Implementation Session:

```
MANDATORY - LOAD ALL 4 RULES NOW:
1. workflow.md (ALWAYS first - time logging, CI requirements)
2. phoenix.md (Phoenix patterns, LiveView)
3. elixir-code-generation.md (Elixir style, @spec requirements)
4. elixir-ci.md (CI requirements, zero-tolerance Credo rules)
```

### Implementation Session (Resume Work):

```
IMPORTANT - CHECK CONTEXT.md FIRST to determine what to load:

Base rules (ALWAYS load):
1. workflow.md (ALWAYS first - time logging, CI requirements)
2. phoenix.md (Phoenix patterns, LiveView)
3. elixir-code-generation.md (Elixir style, @spec requirements)
4. elixir-ci.md (CI requirements, zero-tolerance Credo rules)

Additional rules (ONLY if CONTEXT.md shows Figma work pending):
5. ui-implementation.md (Figma workflow, frontend patterns)
6. FIGMA_MAP.md (Figma node ID to Phoenix component mapping)

If CONTEXT.md shows "Figma Status: ✅ COMPLETE", skip ui-implementation.md and FIGMA_MAP.md
```

### Other Session Types:

**Planning**: workflow.md, planning.md, phoenix.md, elixir-code-generation.md, elixir-ci.md
**Bug Fix**: workflow.md, elixir-ci.md (includes test-first requirements), phoenix.md, elixir-code-generation.md
**Feature-specific**: ui-implementation.md (if "figma" or UI work), git.md (if "git")
**Figma Implementation**: ui-implementation.md, FIGMA_MAP.md (always load both for Figma features)

## Key Reminders

- Run `make ci` before claiming completion
- This is LiveView, not REST API - use event handlers, not endpoints
- Fix ALL Credo warnings - no exceptions

PROJECT_CONTEXT.md has everything else. Focus on loading the right rules.

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
3. FILE: ./codegen/plan/overview.md - **READ IMMEDIATELY**. Feature goals, architecture, step sequence.
4. FILE: ./codegen/plan/steps/ - **READ BASED ON CONTEXT.md** - Only load specific step files when working on that step.
   - Step files use naming convention: `step-01-setup.md`, `step-02-core.md`, etc.
   - **DISCOVERY**: If step file not found, use Glob tool: `./codegen/plan/steps/step-01*.md` to find the actual filename
5. FILE: ./codegen/FIGMA_MAP.md - **CHECK CONTEXT.md FIRST** - Only read if Figma work is pending.
6. FILE: ./codegen/CONTEXT.md - **ALWAYS READ WHEN RESUMING** to determine current stage and which step files to load.

## 🚨 CRITICAL: AUTOMATIC STEP VERIFICATION PROCESS

**MANDATORY FOR EVERY STEP**: This process is **AUTOMATIC** and **NON-NEGOTIABLE**. Never proceed to the next step without completing ALL verification requirements.

### BEFORE IMPLEMENTING ANY STEP:

1. **Find the step plan file**:
   - Check CONTEXT.md for current step (e.g., "step-01-setup.md")
   - If file not found with exact name, use Glob: `./codegen/plan/steps/step-01*.md`
   - Read the found file to understand requirements
2. **Identify ALL verification requirements** from the plan and CONTEXT.md
3. **Create step context file** in `./codegen/context/` using same filename as the plan step

### DURING STEP IMPLEMENTATION:

1. **Implement the step** according to the plan
2. **Update step context file** with implementation details and any deviations

### ⚠️ BEFORE PROCEEDING TO NEXT STEP - AUTOMATIC VERIFICATION:

**STEP 1: Run ALL Required Verification Commands**
Based on the feature type, run ALL applicable commands:

```bash
# ALWAYS REQUIRED:
./codegen/ci.sh                    # Must show "✅ CI checks passed" (includes mix compile)

# FEATURE-SPECIFIC (check plan, CONTEXT.md, and mix.exs for requirements):
mix test                          # Standard test suite
mix test path/to/specific_test.exs # Specific tests mentioned in plan
mix test.features                 # If mix.exs contains this alias (feature test projects)
mix phx.server                    # Manual server verification if needed
```

**STEP 2: Document Verification Evidence**
Update `./codegen/CONTEXT.md` with:

- ✅ Status for each verification command
- Timestamp of successful completion
- Evidence (test counts, coverage %, CI output)
- Any issues resolved during verification

**STEP 3: Complete Step Context File**
Update `./codegen/context/step-XX-name.md` with:

- **Implementation Summary**: What was built
- **Verification Results**: All commands run and results
- **Issues Resolved**: Problems encountered and solutions
- **Lessons Learned**: Key insights for future steps
- **Deviations from Plan**: Any changes made and why

**STEP 4: Update Main Context**
Update `./codegen/CONTEXT.md`:

- Mark current step as ✅ COMPLETE
- Update "Current Step" to next step
- Add verification evidence section
- Update "Implementation Progress"

### 🛑 NEVER PROCEED WITHOUT:

- ✅ ALL verification commands passing
- ✅ Step context file completed
- ✅ Main CONTEXT.md updated with evidence
- ✅ CI showing "✅ CI checks passed"
- ✅ All feature-specific tests passing

### Verification Command Discovery

**How to identify required verification commands:**

1. **Check the step plan** - Look for "Verification" or "Testing" sections
2. **Check CONTEXT.md** - Look for feature-specific requirements
3. **Check mix.exs aliases** - Look for custom test commands
4. **Standard commands** - Always run `./codegen/ci.sh`

**Common verification patterns by feature type:**

- **Feature Tests**: `mix test.features` (if project has this alias)
- **LiveView Features**: `mix test`, server verification
- **API Features**: `mix test`, endpoint testing
- **Database Changes**: `mix test`, `mix ecto.migrate`
- **Frontend Changes**: `mix test`, browser verification

**CRITICAL**: Never proceed to the next step until current step is verified working. Better to fix issues immediately than debug a broken system at the end.

**Why This Matters**: Step verification prevents cascading failures and ensures each piece works before building on top of it. Context files are consolidated during `ocg rm` and used by `ocg update-context` to extract learnings.

## 🚨 CRITICAL: COMPLETE STEP PLAN IMPLEMENTATION

**MANDATORY**: Every step plan requirement MUST be implemented exactly as specified.

### Implementation Completeness Check

**BEFORE claiming step completion:**

1. **Line-by-Line Plan Verification**:

   - Read the entire step plan file (`./codegen/plan/steps/step-XX-name.md`)
   - Create a checklist of EVERY requirement listed
   - Verify each requirement is implemented exactly as specified
   - Check ALL file modifications, configuration changes, dependency additions

2. **Missing Implementation = BLOCKING FAILURE**:

   - ANY unimplemented requirement blocks step completion
   - No partial completions allowed
   - No "we'll do it later" exceptions
   - Must fix immediately before proceeding

3. **Common Missed Requirements**:
   - Configuration file updates (.dockerignore, .gitignore, config files)
   - Dependency version specifications
   - File creation in exact locations specified
   - Environment variable configurations
   - Mix alias definitions

### Step Context Documentation

**MANDATORY**: Document implementation completeness in step context files:

```markdown
## Implementation Checklist

### Requirements from step-XX-name.md:

- [ ] Requirement 1: Description - STATUS: ✅ IMPLEMENTED / ❌ MISSING
- [ ] Requirement 2: Description - STATUS: ✅ IMPLEMENTED / ❌ MISSING
- [ ] etc.

### Verification Evidence:

- Command 1: Result and timestamp
- Command 2: Result and timestamp

### Deviations from Plan:

- None OR list specific changes and justification
```

**CRITICAL**: Step completion requires 100% requirement implementation - zero tolerance for gaps.

## Rule Loading by Session Type

**CRITICAL**: These are MANDATORY, not optional. Load ALL listed rules for your session type IMMEDIATELY.

### Implementation Session (New or Resume):

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

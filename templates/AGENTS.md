# AGENTS.md

Universal guidance for AI agents in OCG workspaces.

## ⚠️ MANDATORY: Load Your Rules FIRST

**CRITICAL - BEFORE taking ANY action:**

1. **STOP** - Do NOT proceed without loading rules
2. **IDENTIFY** your agent type from your prompt/role
3. **LOAD** appropriate rules from `./codegen/rules/INDEX.md`:
   - **ALL agents**: Load shared rules for universal knowledge
   - **Main/Orchestrator**: ALSO load ALL orchestration rules
   - **Specialized Subagents**: ALSO load your domain-specific rules from subagents/
4. **APPLY** these rules to every action you take

**Rule Loading Strategy:**

- **Orchestrators**: Load orchestration rules (delegation-patterns.md, resource management, parallel strategies) + conditionally load UI delegation patterns if plan mentions UI/design work
- **Subagents**: Your role definition file specifies exactly which rules to load - follow that list precisely
- **All Agents**: Always load shared rules (server-management, subagent-core-rules)

## 🚨 Planning vs Implementation Rule Separation

**CRITICAL: NEVER load planning rules during implementation**

ALL agents (orchestrator and subagents) must follow:

❌ **FORBIDDEN during implementation**:

- `planning.md` (planning sessions only)
- `planning-poc.md` (PoC planning sessions only)

✅ **Use these rules ONLY during**:

- `ocg bird-eye` sessions
- `ocg plan` sessions
- Planning mode contexts

**Why forbidden**: Planning rules contain constraints and timelines for planning sessions. Loading during implementation creates confusion between planning goals and implementation execution.

**🚨 CRITICAL: Cross-Role Rule Contamination**

**PROBLEM**: Implementation rules (like `testing.md`, `workflow.md`, `ci-pipeline.md`) are loaded by multiple agent roles but contain role-specific commands that could mislead other agents.

**SOLUTION - Role-Based Rule Loading Restrictions**:

**NEVER LOAD THESE RULES** unless specified in your role template:

- **`code-review.md`**: ONLY for code-reviewer (systematic searches, git diff analysis)
- **`verification-workflow.md`**: ONLY for verification-engineer (CI execution, comprehensive testing)

**SOLUTION - Command Filtering by Role**:

- **When you load a rule file, ONLY follow commands appropriate for your role**
- **Rule files may contain examples for different roles - ignore commands outside your role**
- **Your role template specifies exactly which rules to load - never deviate from that list**

**Role-Specific Command Restrictions**:

**Why restrictions exist**: Prevents cross-role contamination where agents see commands in shared rules and think they can execute them.

### Command Authority Matrix

| Command                            | verification-engineer | feature-developer | code-reviewer | test-engineer |
| ---------------------------------- | --------------------- | ----------------- | ------------- | ------------- |
| `./codegen/ci.sh`                  | ✅ Full suite         | ❌ FORBIDDEN      | ❌ FORBIDDEN  | ❌ FORBIDDEN  |
| `mix test` (no args)               | ✅ Full suite         | ❌ FORBIDDEN      | ❌ FORBIDDEN  | ❌ FORBIDDEN  |
| `mix test test/file.exs`           | ✅ Allowed            | ✅ Targeted only  | ❌ FORBIDDEN  | ✅ During dev |
| `mix credo --strict`               | ✅ Full scan          | ✅ Self-check     | ❌ Read only  | ✅ Self-check |
| `mix compile --warnings-as-errors` | ✅ Verification       | ✅ Self-check     | ❌ FORBIDDEN  | ✅ Self-check |

**Critical distinctions**:

- `mix test` = full suite = verification-engineer ONLY
- `mix test test/specific_file.exs` = targeted = feature-developer OK during development
- code-reviewer NEVER executes, only analyzes

### Translation File Staging (EXCLUSIVE)

**ONLY translator agent** can stage .po/.pot files:

| Command                         | translator   | ALL other agents        |
| ------------------------------- | ------------ | ----------------------- |
| `git add priv/gettext/**/*.po`  | ✅ EXCLUSIVE | ❌ ABSOLUTELY FORBIDDEN |
| `git add priv/gettext/**/*.pot` | ✅ EXCLUSIVE | ❌ ABSOLUTELY FORBIDDEN |
| `git add *.po`                  | ✅ EXCLUSIVE | ❌ ABSOLUTELY FORBIDDEN |

**Why this matters**:

- `make ci` expects translation files staged ONLY by translator
- Other agents staging .po/.pot files causes CI pipeline failures
- Translator has specialized workflow for gettext file management

**If you need translation files staged**:

- ❌ DO NOT stage them yourself
- ✅ Report to orchestrator: "Translation files need staging - delegate to translator"

**Example**: If `testing.md` shows `./codegen/ci.sh`, only verification-engineer should execute it. Other agents should treat it as documentation only.

**WHY**: Prevents agents from loading inappropriate rules and running inappropriate commands even when those appear in legitimately-accessible rule files.

**🚨 CRITICAL RULE HIERARCHY:**

- **Each role has context-dependent critical rules** that take precedence over all other guidance
- **Orchestrators**: `delegation-patterns.md` always overrides everything
- **Subagents**: Multiple critical rules depending on task context:
  - **Always critical**: Core domain rules (e.g., `phoenix.md` for feature-developer)
  - **Context critical**: Task-specific rules (e.g., `feature-tests.md` when doing browser tests)
  - **Orchestrator specifies context** in delegation prompts
- **If ANY conflict exists** between critical rules and other sources, the critical rules WIN
- **Follow critical rules exactly** - no exceptions, no shortcuts, no interpretations

**✅ ALWAYS:**

- Load rules as your FIRST action
- **READ COMPLETE FILES**: Use Read tool WITHOUT limit/offset parameters to get full file content
- Follow your role definition's rule loading instructions
- Apply rules consistently throughout your work
- **DOCUMENT RULE LOADING**: Prove you loaded rules by showing actual content
- **PROVIDE EVIDENCE**: Document systematic search execution in session logs

**❌ NEVER:**

- Skip rule loading
- **Use limit/offset parameters when reading rule files** - read complete files only
- Assume you know patterns without checking rules
- Ignore your role definition's required rules
- **Claim completion without proof of rule compliance**
- **Skip systematic searches required by your role**

## 🚨 MANDATORY: Rule Compliance Verification

**CRITICAL - All agents must prove rule compliance before claiming completion:**

1. **Document rule loading** - Show actual rule content in your session log
2. **Execute required searches** - Run all systematic searches your role requires
3. **Provide proof** - Session log must contain evidence of compliance
4. **No exceptions** - Claims without proof will be rejected

**Why**: Prevents agents from ignoring rules and ensures quality standards.

## 🚨 MANDATORY: MCP Tool Failure Protocol

**CRITICAL - All agents load the shared MCP tool failure protocol:**

- **Load**: `./codegen/rules/shared/mcp-tool-failure-protocol.md`
- **Required for**: ui-specialist, feature-developer, verification-engineer
- **Contains**: Immediate tool verification, failure reporting, workflow blocking rules

**RATIONALE**: Working without MCP tools produces broken/incomplete results. Better to fail fast and get tools fixed than waste time on unusable work.

## Workspace Rules

**OCG Workspace (Git Worktree)**:

- Work in current directory only (never `../` or `../../`)
- All files are in current workspace
- Check `./codegen/CONTEXT.md` for ports/settings

## Universal Context Files

**ALL agents must read**:

- `./codegen/PROJECT_CONTEXT.md` - Project architecture and patterns
- `./codegen/CONTEXT.md` - Workspace state, ports, progress

**UI-related agents should also read** (if files exist):

- `./codegen/FIGMA_MAP.md` - Figma node ID to Phoenix component mappings
- `./codegen/FIGMA_DESIGN_SYSTEM_RULES.md` - Figma design system rules and guidelines
- `./codegen/FIGMA_TOKEN_MAPPING.md` - Figma design token mappings

## Recipe System

**IMPORTANT**: If the orchestrator provides recipe references in your task prompt, use them! Recipes contain proven patterns and solutions.

**Example delegation with recipe:**

```
Task: "Fix async test failures"
HELPFUL RESOURCES: See ./codegen/recipes/phoenix-async-feature-testing.md
```

**Your job**: Follow the recipe pattern provided by the orchestrator. Don't search for recipes yourself - the orchestrator handles recipe discovery to save context window space.

## 📚 Library Usage Rules

**IMPORTANT**: When working with external Elixir libraries, load library-specific usage documentation to ensure correct implementation patterns.

**Usage rules location**: `$OCG_CONTEXT_DIR/usage_rules/` (typically `~/Areas/Optimum/context/usage_rules/`)

### When to Load Usage Rules

**Load library-specific documentation BEFORE implementing with that library:**

- Working with **Jason** → Load `jason-1.4.4.md` (JSON encoding/decoding patterns)
- Working with **Ecto** → Load `ecto-*.md` files (database queries, changesets, migrations)
- Working with **Phoenix LiveView** → Load `phoenix_live_view-*.md` files (components, forms, JS interop)
- Working with **Gettext** → Load `gettext-*.md` (i18n patterns, translation extraction)
- Working with **Floki** → Load `floki-*.md` (HTML parsing, testing selectors)
- Working with **Any other library** → Check `ls $OCG_CONTEXT_DIR/usage_rules/` for available documentation

### How to Load Usage Rules

**Pattern**: Files are named `{library_name}-{version}.md` (e.g., `jason-1.4.4.md`, `ecto-3.11.2.md`)

**Discovery workflow:**

```bash
# 1. List all available library documentation
ls $OCG_CONTEXT_DIR/usage_rules/

# 2. Use grep to find the library you need (case-insensitive, pattern matching)
ls $OCG_CONTEXT_DIR/usage_rules/ | grep -i "jason"
# Output: jason-1.4.4.md

ls $OCG_CONTEXT_DIR/usage_rules/ | grep -i "phoenix_live_view"
# Output: phoenix_live_view-1.0.0.md
#         phoenix_live_view-1.0.0-components.md
#         phoenix_live_view-1.0.0-forms.md
#         ... (multiple topic files)

# 3. Load the found file(s)
Read file_path="$OCG_CONTEXT_DIR/usage_rules/jason-1.4.4.md"

# For frameworks with multiple files, start with the main index
Read file_path="$OCG_CONTEXT_DIR/usage_rules/phoenix_live_view-1.0.0.md"
# Then load topic-specific files as needed
Read file_path="$OCG_CONTEXT_DIR/usage_rules/phoenix_live_view-1.0.0-components.md"
```

**Quick search pattern:**

```bash
# Find all docs for a library (handles version variations)
ls $OCG_CONTEXT_DIR/usage_rules/ | grep -i "^library_name"

# Examples:
ls $OCG_CONTEXT_DIR/usage_rules/ | grep -i "^ecto"      # ecto-3.11.2.md
ls $OCG_CONTEXT_DIR/usage_rules/ | grep -i "^gettext"   # gettext-0.25.0.md
ls $OCG_CONTEXT_DIR/usage_rules/ | grep -i "^floki"     # floki-0.36.3.md
```

### Framework Libraries (Multi-File Documentation)

**Large frameworks split into topic-specific files:**

- **Phoenix LiveView**: Multiple files covering fundamentals, components, forms, navigation, uploads, JS interop, security
- **Ecto**: Database patterns, changesets, queries, migrations
- **Phoenix**: Routing, controllers, views, channels

**Strategy**: Load the main index file first, then load topic-specific files as needed.

```bash
# Example: Phoenix LiveView work
Read file_path="$OCG_CONTEXT_DIR/usage_rules/phoenix_live_view-1.0.0.md"  # Main index
Read file_path="$OCG_CONTEXT_DIR/usage_rules/phoenix_live_view-1.0.0-components.md"  # Topic file
```

### Generating Missing Usage Rules

**If usage rules don't exist for a library you're working with:**

```bash
# Run this command to generate documentation for all project dependencies
ocg usage-rules

# This reads mix.exs, extracts dependencies, and generates usage documentation from hexdocs.pm
```

**Why load usage rules:**

- Ensures correct API usage patterns
- Prevents common mistakes and antipatterns
- Provides version-specific guidance (APIs change between versions)
- Saves context by focusing on library-specific patterns instead of general knowledge

**When NOT needed:**

- Built-in Elixir/Erlang modules (Logger, Enum, Map, etc.)
- Libraries you're already expert in
- Simple one-function utilities

## 📊 MANDATORY: Session Logging

**ALL agents** must create session logs as SECOND action (after loading rules).

**Standard Format**:

```bash
LOG_FILE="./codegen/logging/$(date -u +%Y%m%d_%H%M%S)_[role].md"
```

**Role values**:

- orchestrator
- feature-developer
- verification-engineer
- code-reviewer
- test-engineer
- ui-specialist
- translator
- devops-manager
- infrastructure-architect
- poc-developer

**Example**:

```bash
# For orchestrator:
./codegen/logging/20250930_143022_orchestrator.md

# For feature-developer:
./codegen/logging/20250930_143156_feature-developer.md
```

**WHEN**:

1. Create log file as your SECOND action (after loading rules)
2. **UPDATE CONTINUOUSLY** - Edit the log file throughout your session
3. Update after each major action (delegation, tool use, file modification)

**LOG FORMAT**:

```markdown
# Session Log: <agent_role>

**Started**: $(date -u)
**Task**: [Brief description of main task]

## Rules & Context Loaded

- [ ] ./codegen/rules/INDEX.md
- [ ] ./codegen/PROJECT_CONTEXT.md
- [ ] ./codegen/CONTEXT.md
- [ ] phoenix.md
- [ ] testing.md
- [ ] [list each rule file you actually loaded]

## Recipes Used

- [ ] /path/to/recipe.md (if any were provided by orchestrator)

## Library Usage Rules Loaded

**IMPORTANT: Track which library-specific documentation you loaded to ensure correct API usage**

- [ ] jason-1.4.4.md (JSON encoding/decoding)
- [ ] phoenix_live_view-1.0.0-components.md (LiveView components)
- [ ] gettext-0.25.0.md (i18n patterns)
- [ ] [list each library usage rule you loaded]
- [ ] No library-specific rules loaded (if not working with external libraries)

## MCP Tools Used

**IMPORTANT: Track ACTUAL tool usage, not planned usage. Update this section each time you call an MCP tool.**

- [ ] Figma MCP: get_image (2), get_code (1), get_variable_defs (1) = 4 total calls
- [ ] Playwright MCP: browser_screenshot (3), browser_navigate (2) = 5 total calls
- [ ] Tidewave MCP: project_eval (6), get_source_location (0) = 6 total calls
- [ ] No MCP tools used (if none were actually called)

## Command Execution Log

**CRITICAL: Log EVERY command with timestamp and duration to debug performance issues**

| Time     | Duration | Command                      | Status | Notes                    |
| -------- | -------- | ---------------------------- | ------ | ------------------------ |
| 08:25:30 | 2.1s     | `mix compile`                | ✅     | Clean compilation        |
| 08:25:33 | 0.8s     | `mix test --only smoke_test` | ✅     | All smoke tests pass     |
| 08:25:45 | 12.3s    | `./codegen/ci.sh`            | ❌     | Failed on gettext checks |
| 08:25:47 | 1.2s     | `mix gettext.extract`        | ✅     | Fixed gettext issue      |
| 08:25:49 | 8.9s     | `./codegen/ci.sh`            | ✅     | All checks pass          |

**Track patterns:**

- ✅ **Success patterns**: Commands that work well (reuse these)
- ❌ **Failed commands**: Commands that failed (avoid/fix these)
- ⏱️ **Performance**: Commands taking >30s (investigate why)

## Files Modified

- [ ] src/lib/component.ex (created/updated)
- [ ] test/feature_test.exs (created)
- [ ] [list all files you created/modified]

## Delegation (orchestrator only)

**CRITICAL: Log delegations BEFORE calling Task() to prevent information loss on crashes.**

**WORKFLOW:**

1. **FIRST**: Add delegation entry with "IN PROGRESS" status
2. **THEN**: Call Task() tool
3. **AFTER**: Update status based on subagent results

**Example tracking:**

- [x] Delegating to feature-developer: "implement user registration" → IN PROGRESS
- [x] Delegated to feature-developer: → COMPLETED
- [x] Delegating to verification-engineer: "verify implementation" → IN PROGRESS
- [x] Delegated to verification-engineer: → FOUND 2 ISSUES
- [x] Delegating to feature-developer: "fix issues" → IN PROGRESS
- [x] Delegated to feature-developer: → COMPLETED
- [ ] N/A - Not an orchestrator

## Lessons Learned (for CONTEXT.md)

**CRITICAL: Document what worked/didn't work to avoid repeating mistakes and reuse successful patterns**

### ✅ What Worked Well

- [Command/approach that worked]: [Why it was effective]
- [Successful pattern]: [When to use this again]

### ❌ What Failed/Was Slow

- [Failed command]: [Why it failed, how to avoid]
- [Slow process]: [What caused the delay, alternatives to try]

### 🔄 Recommendations for Next Time

- [Specific command sequence that worked efficiently]
- [Tools/approaches to avoid]
- [Performance optimizations discovered]

**SAVE TO CONTEXT.md**: Update `./codegen/CONTEXT.md` with key lessons from this section to improve future iterations.

## Completion Status

- [x] All tasks completed successfully
- [ ] Blocked by: [reason if incomplete]
```

**BASH COMMAND for timestamp**: `date -u +%Y%m%d_%H%M%S`

**WHY**: This helps debug whether OCG rules loading, MCP tool access, and multi-agent coordination are working properly.

## Work Context Management (Agent-to-Agent Communication)

**All agents use bash commands directly for work contexts:**

### Checking for Work (All Agents at Session Start)

```bash
# Check for pending work
ls ./codegen/context/PENDING-* 2>/dev/null || echo "No PENDING work"

# Check for interrupted work
ls ./codegen/context/ACTIVE-* 2>/dev/null || echo "No ACTIVE work"
```

### Creating Work Contexts (Orchestrator Before Delegating Issues)

```bash
# Create issue context with full details
TIMESTAMP=$(date -u +"%Y%m%d-%H%M%S")
cat > ./codegen/context/PENDING-issues-${TIMESTAMP}-code-review.md << 'EOF'
# Code Review Issues
**Source**: code-reviewer
**Target**: feature-developer
**Status**: PENDING

## Issues Found
[PASTE FULL REVIEW REPORT HERE]
EOF
```

### Managing Work Contexts (Subagents)

```bash
# When starting work on an issue
mv ./codegen/context/PENDING-issues-*.md ./codegen/context/ACTIVE-issues-*.md

# When completing work
mv ./codegen/context/ACTIVE-issues-*.md ./codegen/context/RESOLVED-issues-*.md
```

## Universal Requirements

- **100% task completion** - Finish all assigned work completely
- **Check work contexts** - Always check `./codegen/context/PENDING-*` at session start
- **Update work contexts** - Move through PENDING→ACTIVE→RESOLVED as you work
- **Workspace isolation** - Never navigate outside current directory
- **Port awareness** - Use ports from CONTEXT.md, not hardcoded values
- **Server management** - Phoenix server is already running; only restart if explicitly needed
- **Create session logs** - ALL agents must log (not just orchestrator)

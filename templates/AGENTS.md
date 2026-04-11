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

**PROBLEM**: Implementation rules (like `testing.md`, `workflow.md`, `github-actions.md`) are loaded by multiple agent roles but contain role-specific commands that could mislead other agents.

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

| Command                            | verification-engineer | phoenix-developer | code-reviewer | test-engineer |
| ---------------------------------- | --------------------- | ----------------- | ------------- | ------------- |
| `make ci`                          | ✅ Full suite         | ❌ FORBIDDEN      | ❌ FORBIDDEN  | ❌ FORBIDDEN  |
| `mix test` (no args)               | ✅ Full suite         | ❌ FORBIDDEN      | ❌ FORBIDDEN  | ❌ FORBIDDEN  |
| `mix test test/file.exs`           | ✅ Allowed            | ✅ Targeted only  | ❌ FORBIDDEN  | ✅ During dev |
| `mix credo --strict`               | ✅ Full scan          | ✅ Self-check     | ❌ Read only  | ✅ Self-check |
| `mix compile --warnings-as-errors` | ✅ Verification       | ✅ Self-check     | ❌ FORBIDDEN  | ✅ Self-check |

**Critical distinctions**:

- `mix test` = full suite = verification-engineer ONLY
- `mix test test/specific_file.exs` = targeted = phoenix-developer OK during development
- code-reviewer NEVER executes, only analyzes

### Translation File Staging

**See `git.md` for translation file staging rules.** Only translator agent can stage .po/.pot files.

**WHY**: Prevents agents from loading inappropriate rules and running inappropriate commands even when those appear in legitimately-accessible rule files.

**🚨 CRITICAL RULE HIERARCHY:**

- **Each role has context-dependent critical rules** that take precedence over all other guidance
- **Orchestrators**: `delegation-patterns.md` always overrides everything
- **Subagents**: Multiple critical rules depending on task context:
  - **Always critical**: Core domain rules (e.g., `phoenix.md` for phoenix-developer)
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
- **Required for**: ui-specialist, phoenix-developer, verification-engineer
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

**ALL agents** must create session logs. See `shared/session-management.md` for complete logging format.

**Quick reference**:

- **File**: `./codegen/logging/$(date -u +%Y%m%d_%H%M%S)_[role].md`
- **When**: Create as SECOND action (after loading rules)
- **Update**: Continuously throughout session (not at end)

**Critical rules**:

1. Mark `[x]` checkboxes ONLY after reading file with Read tool
2. Log commands with timestamp/duration for debugging
3. Save lessons learned to `./codegen/CONTEXT.md`

**WHY**: Helps debug rule loading, MCP tool access, and multi-agent coordination.

## Work Context Management (Agent-to-Agent Communication)

**See `shared/session-management.md` for work context file management.**

**🚨 CRITICAL: ALWAYS use RELATIVE paths for context files!**

```bash
# ✅ CORRECT - relative paths (works in any workspace)
./codegen/context/PENDING-*.md
./codegen/context/RESOLVED-*.md

# ❌ WRONG - absolute paths (writes to wrong location!)
/Users/.../bemeda_personal/codegen/context/PENDING-*.md
```

**Why this matters:**

- Workspaces are git worktrees with their OWN `./codegen/context/` directory
- Using absolute paths writes to the MAIN project, not the workspace
- Files in the wrong location are INVISIBLE to other agents

**Quick reference**:

- Location: `./codegen/context/` (RELATIVE PATH!)
- Prefixes: `PENDING-*`, `ACTIVE-*`, `RESOLVED-*`
- Check at session start: `ls ./codegen/context/PENDING-* 2>/dev/null`

## Universal Requirements

- **100% task completion** - Finish all assigned work completely
- **Issue Discovery → Immediate Fixing** - If you find issues, create PENDING files AND immediately fix them (NEVER stop after just documenting)
- **Check work contexts** - Always check `./codegen/context/PENDING-*` at session start
- **Update work contexts** - Move through PENDING→ACTIVE→RESOLVED as you work
- **Workspace isolation** - Never navigate outside current directory
- **Port awareness** - Use ports from CONTEXT.md, not hardcoded values
- **Server management** - Phoenix server is already running; only restart if explicitly needed
- **Create session logs** - ALL agents must log (not just orchestrator)

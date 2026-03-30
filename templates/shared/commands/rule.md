---
description: Add a new rule or principle with automatic orchestration/implementation separation
argument-hint: [rule description]
---

Extract lessons from conversation and add concise rules. **CRITICAL: Keep rules short and action-oriented.**

## Writing Guidelines

**📚 Complete style guide**: Read `~/Areas/Optimum/context/rules/STYLE_GUIDE.md` before writing any rules. It covers:

- Emoji and criticality marker usage
- Wording standards and consistency
- Cross-role rule contamination prevention
- Rule maintenance workflows

**✅ CONCISE RULE PRINCIPLES**:

- **Max 10 lines per rule section** - No verbose explanations
- **Action-oriented** - Start with commands/searches, not theory
- **One concept per rule** - Don't combine multiple patterns
- **Bullet points over paragraphs** - Easy to scan and apply
- **Examples over explanations** - Show, don't tell

**❌ AVOID VERBOSITY**:

- Long explanations of why rules exist
- Multiple search strategies for same concept
- Excessive command examples
- Redundant violation categories
- Detailed impact descriptions

## Process

1. **Extract lessons** from conversation (errors, solutions, patterns discovered)
2. **Write concisely** - Max 5-10 lines per rule
3. **Classify each lesson**:
   - **Orchestration** → `./codegen/rules/orchestration/`
   - **Implementation** → `./codegen/rules/subagents/`
   - **Both** → Split into appropriate parts

## Classification Keywords

**Orchestration signals**:

- Parallel execution, delegation patterns, port allocation
- Resource management, coordination, timing/sequencing
- Subagent selection, workload distribution
- Bottlenecks, blocking tasks, sequential requirements
- Discovery → Distribution patterns
- Examples: "run 3 subagents in parallel", "migration blocks everything", "can't parallelize"

**Implementation signals**:

- Code patterns, API usage, framework specifics
- Bug fixes, error handling, testing approaches
- Migration syntax, debugging techniques
- Examples: "export PORT_TEST before mix test", "use LiveView events"

**Bottleneck signals** (create BOTH types):

- "Blocks all other work", "must complete first"
- "System won't start", "everything failing"
- "Migration required", "authentication broken"
- Create orchestration rule for sequencing AND implementation rule for fix

## File Placement

**🔍 FIRST: Check INDEX.md for file distinctions**

Before adding a rule, check `./codegen/rules/INDEX.md` section "🔍 File Distinction Guide" to understand file boundaries.

### Orchestration Rules (`rules/orchestration/`)

- **parallel-testing.md** - Test parallelization strategies
- **parallel-task-patterns.md** - Task decomposition and parallelization
- **bottleneck-patterns.md** - Sequential work, blocking tasks
- **delegation-patterns.md** - Subagent selection and coordination
- **step-context-management.md** - Step context coordination, integration checkpoints
- **recipe-management.md** - Recipe documentation patterns
- **resource-management.md** - Port/database allocation

### Implementation Rules (`rules/subagents/`)

**Backend Development:**

- **phoenix.md** - Phoenix/LiveView patterns, contexts, routing
- **testing.md** - Phoenix/Elixir testing (ExUnit, mix test, LiveView tests)
- **elixir-code-generation.md** - Code style, patterns
- **i18n.md** - Internationalization, Gettext
- **workflow.md** - Development workflow, CI requirements

**Mobile Development:**

- **flutter.md** - Flutter/Dart patterns, state management
- **mobile-testing.md** - Flutter testing (flutter test, widget tests, integration tests)

**Testing File Distinction** (🚨 CRITICAL - commonly confused):

- **testing.md**: Backend testing (mix test, ExUnit, Phoenix LiveView)
  - Keywords: mix test, ExUnit, LiveView testing, Ecto, ./codegen/ci.sh
- **mobile-testing.md**: Mobile testing (flutter test, widget tests)
  - Keywords: flutter test, dart, widget tests, tester.pump, integration_test

**Rule of thumb**: If it uses `mix test`, add to `testing.md`. If it uses `flutter test`, add to `mobile-testing.md`.

## Examples

### Example 1: Parallel Work

**Input**: "parallel test fixing with port allocation"

**Creates two rules**:

1. `orchestration/parallel-testing.md`: Port derivation formula, delegation with unique ports
2. `testing.md`: Using PORT_TEST environment variable in tests

### Example 2: Bottleneck

**Input**: "database migration blocks all work until complete"

**Creates two rules**:

1. `orchestration/bottleneck-patterns.md`: Migration must complete before parallelization
2. `phoenix.md`: How to create and run migrations properly

### Example 3: Discovery Pattern

**Input**: "qa-engineer found translation failures, orchestrator distributes per file"

**Creates**:

1. `orchestration/delegation-patterns.md`: Discovery → Distribution flow for translations
2. `i18n.md`: How to fix missing translation keys

## Auto-Update INDEX.md

After adding rules, update the index with:

- Rule location and category
- Brief description
- Which agents should load it

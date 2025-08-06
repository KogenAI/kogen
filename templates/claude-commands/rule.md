---
description: Add a new rule or principle with automatic orchestration/implementation separation
argument-hint: [rule description]
---

Analyze the conversation to extract lessons, then automatically separate orchestration vs implementation aspects.

## Process

1. **Extract lessons** from conversation (errors, solutions, patterns discovered)
2. **Classify each lesson**:
   - **Orchestration** → `./codegen/rules/orchestration/`
   - **Implementation** → `./codegen/rules/`
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

### Orchestration Rules (`rules/orchestration/`)

- **parallel-testing.md** - Test parallelization strategies
- **bottleneck-patterns.md** - Sequential work, blocking tasks
- **role-orchestration-patterns.md** - Discovery → Distribution flow
- **task-based-delegation.md** - Context-efficient task sizing
- **delegation-patterns.md** - Subagent coordination
- **resource-management.md** - Port/database allocation

### Implementation Rules (`rules/`)

- **phoenix.md** - LiveView patterns, contexts
- **testing.md** - Test writing, fixtures
- **elixir-code-generation.md** - Code style, patterns

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

1. `orchestration/role-orchestration-patterns.md`: Discovery → Distribution flow for translations
2. `i18n.md`: How to fix missing translation keys

## Auto-Update INDEX.md

After adding rules, update the index with:

- Rule location and category
- Brief description
- Which agents should load it

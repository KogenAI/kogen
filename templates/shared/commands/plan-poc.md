---
description: Analyze a business idea and create a planning prompt for OCG's planning system
argument-hint: [path to business concept file]
---

Analyze business concept document and prepare prompt for `ocg plan`.

**STEP 1: Business Concept Analysis**

Ask user for path to business concept markdown file, then extract:

- **Core value proposition** — main problem being solved
- **Key assumptions** — beliefs needing validation
- **Success metrics** — how we know if it works
- **Technical complexity** — hardest parts to build
- **User workflow** — simplest path to value

Identify the "magic moment" that makes users say "this is useful."

**STEP 2: PoC Scope Analysis**

- Extract 3-5 most critical assumptions to validate
- Define what NOT to build (auth, persistence, mobile, etc.)
- Identify core workflow (3-7 steps max)
- Focus on the "aha moment" validating the concept

**STEP 3: Technical Constraints Analysis**

- List critical external APIs, libraries, or tools needed
- Note non-Elixir integrations (Python libraries, etc.)
- Identify technical risks
- Map how external tools integrate with Phoenix/Elixir

**STEP 4: Success Criteria Definition**

- Technical: what assumptions need proving? Acceptable performance thresholds?
- User: what behaviors need validation? What completion rates indicate success?
- Business: what metrics prove this solves a real problem?

**STEP 5: Create OCG Planning Prompt**

Create `./codegen/prompts/poc-planning-prompt.md`:

```markdown
# PoC Planning Session

**Business Concept Reference**: {path}

## Core Value Proposition

{extracted}

## Critical Assumptions to Validate

{list}

## PoC Scope Boundaries

{what NOT to build}

## Core User Workflow

{simplified user journey}

## Technical Constraints

{external deps and integration reqs}

## Success Criteria

{validation questions}

## Planning Instructions

Create detailed PoC impl plan that:

1. Validates core assumptions through minimal viable impl
2. Uses Phoenix LiveView for interactive features
3. Integrates external tools via System.cmd() with error handling
4. Focuses on rapid validation over feature completeness
5. Plans for 2-4 week timeline with iterative testing

**CRITICAL PoC PATTERNS:**

- **NO persistent storage** — ETS for temporary session data only
- **NO authentication** — skip user accounts entirely
- **NO comprehensive testing** — basic smoke tests only
- **NO production infrastructure** — simple single-instance
- **YES external tool integration** — System.cmd() for Python libs
- **YES real-time updates** — LiveView for processing feedback
- **YES validation metrics** — build in feedback collection
```

**STEP 6: Setup Instructions**

```bash
mkdir {project_name}
cursor {project_name}

# Inside Cursor:
mix phx.new . --app {project_name} --database postgres --install

git init && git add . && git commit -m "Initial commit"
ocg setup
cp /Users/almirsarajcic/Areas/Optimum/codegen/templates/AGENTS-POC.md ./AGENTS.md
cp /Users/almirsarajcic/Areas/Optimum/codegen/prompts/poc-planning-prompt.md ./codegen/
ocg plan poc
# When Claude asks for feature description, paste path: ./codegen/poc-planning-prompt.md
ocg new poc
```

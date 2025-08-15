Analyze a business idea from a markdown file and create a focused planning prompt for OCG's planning system.

This command takes a business concept document and prepares a specific prompt for `ocg plan` that will leverage OCG's planning rules and Phoenix/Elixir expertise to create a proper PoC implementation plan.

**STEP 1: Business Concept Analysis**

Ask the user for the path to their business concept markdown file, then analyze:

- **Core value proposition** - What's the main problem being solved?
- **Key assumptions** - What beliefs need validation?
- **Success metrics** - How will we know if it works?
- **Technical complexity** - What are the hardest parts to build?
- **User workflow** - What's the simplest path to value?

Extract the essential "magic moment" that makes users say "this is useful."

**STEP 2: PoC Scope Analysis**

Analyze the business concept to identify the minimal scope that validates core assumptions:

### Critical Assumptions to Validate

- Extract 3-5 most critical assumptions from the business concept
- Focus on user behavior and technical feasibility questions
- Identify the shortest path to meaningful feedback

### PoC Boundaries

- Define what should NOT be built in the PoC (auth, persistence, mobile, etc.)
- Identify core workflow (3-7 steps max)
- Focus on the "aha moment" that validates the concept

**STEP 3: Technical Constraints Analysis**

Identify technical considerations that should guide OCG's planning:

### External Dependencies

- List critical external APIs, libraries, or tools needed
- Note any non-Elixir integrations required (Python libraries, etc.)
- Identify potential technical risks or constraints

### Integration Requirements

- Map out how external tools should integrate with Phoenix/Elixir
- Note any specific technical patterns needed (real-time updates, background processing, etc.)
- Identify data flow requirements

**STEP 4: Success Criteria Definition**

Define specific, measurable validation goals:

### Technical Validation Questions

- What core technical assumptions need proving?
- What are acceptable performance thresholds?
- What integration points are most risky?

### User Validation Questions

- What user behaviors need validation?
- What completion rates indicate success?
- What feedback indicates product-market fit?

### Business Validation Questions

- What metrics prove this solves a real problem?
- What would indicate people would pay for this?
- What differentiates this from alternatives?

**STEP 5: Create OCG Planning Prompt**

Generate a structured prompt for `ocg plan` that includes all the analysis above:

Create a prompt file using Write tool named `./codegen/prompts/poc-planning-prompt.md` with this structure:

```markdown
# PoC Planning Session

**Business Concept Reference**: {path to business concept file}

## Core Value Proposition

{extracted from business concept analysis}

## Critical Assumptions to Validate

{list from Step 2}

## PoC Scope Boundaries

{what NOT to build from Step 2}

## Core User Workflow

{simplified user journey from Step 2}

## Technical Constraints

{external dependencies and integration requirements from Step 3}

## Success Criteria

{validation questions from Step 4}

## Planning Instructions

**FIRST**: Load the PoC-specific planning rules by reading `./codegen/rules/planning-poc.md` completely. This file contains critical PoC patterns that override standard planning approaches.

Create a detailed PoC implementation plan that:

1. **Validates core assumptions** through minimal viable implementation
2. **Uses Phoenix LiveView** for interactive features without frontend complexity
3. **Integrates external tools** via System.cmd() with proper error handling
4. **Focuses on rapid validation** over feature completeness
5. **Plans for 2-4 week timeline** with iterative testing

**CRITICAL PoC PATTERNS TO APPLY**:

- **NO persistent storage** - Use ETS for temporary session data only
- **NO authentication** - Skip user accounts entirely
- **NO comprehensive testing** - Basic smoke tests and integration tests only
- **NO production infrastructure** - Simple single-instance deployment
- **YES external tool integration** - Use System.cmd() for Python libraries
- **YES real-time updates** - LiveView for processing feedback
- **YES validation metrics** - Build in feedback collection for assumption testing

Follow the planning-poc.md rules exactly for infrastructure choices, testing strategy, and development timeline.
```

**STEP 6: Setup Instructions**

After creating the planning prompt, provide these exact commands:

```bash
# 1. Create project directory and open in Cursor
mkdir {project_name}
cursor {project_name}

# 2. Inside Cursor, save workspace then run:
mix phx.new . --app {project_name} --database postgres --install

# 3. Initialize git repository
git init
git add .
git commit -m "Initial commit"

# 4. Set up OCG project context
ocg setup

# 5. Replace with PoC-specific AGENTS template
cp /Users/almirsarajcic/Areas/Optimum/codegen/templates/AGENTS-POC.md ./AGENTS.md

# 6. Copy the planning prompt for easy access
cp /Users/almirsarajcic/Areas/Optimum/codegen/prompts/poc-planning-prompt.md ./codegen/

# 7. Run OCG planning session
ocg plan poc

# 8. When the planning session starts and Claude asks you to describe the feature:
#    - Copy the path: ./codegen/poc-planning-prompt.md
#    - Paste the path (not contents) as your feature description
#    - Claude will read the file and use the PoC planning rules

# 9. After planning is complete, create PoC development workspace
ocg new poc
```

**What this approach provides:**

- ✅ Business concept analysis without duplicating OCG's technical expertise
- ✅ Focused planning prompt that leverages OCG's rule system
- ✅ Proper Phoenix/Elixir patterns from OCG's planning rules
- ✅ Complete project setup with OCG workspace management
- ✅ Separation of concerns: business analysis vs technical planning

This ensures that technical planning is done by OCG with full access to Phoenix/Elixir rules, while the Claude command focuses on business concept analysis and validation scope definition.

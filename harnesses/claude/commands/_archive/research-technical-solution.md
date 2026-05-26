---
description: Conduct comprehensive technical research and analysis for Phoenix/Elixir solutions
---

Systematic research of technical solutions for Phoenix/Elixir apps. Evaluate approaches across setup complexity, performance, maintenance, and production readiness.

**STEP 1: Understanding Research Topic**

Capture:

- Core problem — what technical challenge needs solving
- Context — Phoenix/Elixir application specifics
- Reqs — key criteria (performance, compliance, etc.)
- Constraints — budget, timeline, team expertise

Confirm understanding before proceeding.

**STEP 2: Research Execution**

First, get current year via `date +%Y` to ensure searches include recent info.

Use TodoWrite to create and track research tasks:

1. **Library/Tool Discovery**
   - Search Phoenix/Elixir-specific solutions, include current and previous year in queries (e.g., "Phoenix audit log library 2024 2025")
   - Identify popular libs and patterns
   - Check GitHub activity, maintenance status, last commits
   - Verify compatibility with current Elixir/Phoenix versions

2. **Impl Approaches**
   - DB-level solutions (triggers, functions)
   - App-level patterns (contexts, behaviors)
   - Third-party services and integrations
   - Custom impl strategies

3. **Technical Evaluation**
   - Setup complexity and time estimates
   - Code changes required
   - Performance impact analysis
   - Storage/resource efficiency
   - Scalability considerations

4. **Production Readiness**
   - Active maintenance and community support
   - Documentation quality
   - Known issues and limitations
   - Security considerations
   - Testing strategies

**STEP 3: Detailed Analysis**

For each viable approach:

- Setup Complexity — time estimates, expertise required
- Code Changes — impact on existing codebase with examples
- Performance Impact — concrete metrics, overhead calculations
- Storage Efficiency — real-world calculations
- Business Context — what metadata can be captured
- Gap Risk — potential for missing critical operations
- Maintenance Burden — long-term implications

**STEP 4: Create Analysis Document**

Comprehensive markdown analysis:

## Executive Summary

Brief overview of viable approaches with critical considerations (e.g., deprecated libraries, compatibility issues)

## Detailed Analysis by Approach

### Approach 1: [Name]

**Benefits**

- Key advantages and use cases

**Pros**

- Specific positive aspects

**Cons**

- Limitations and drawbacks

[Repeat for each approach]

## Comparative Analysis

| Criteria         | Approach 1 | Approach 2 | Approach 3 |
| ---------------- | ---------- | ---------- | ---------- |
| Setup Time       |            |            |            |
| Code Changes     |            |            |            |
| Performance      |            |            |            |
| [Other criteria] |            |            |            |

## Recommendations by Use Case

**[Scenario 1]**

- Recommended approach with rationale

**[Scenario 2]**

- Alternative approach for different needs

## Implementation Considerations

- Migration strategies
- Testing approaches
- Monitoring and debugging
- Team training needs

## Conclusion

Summary of findings with clear recommendation for most common use cases

**Research Quality Standards:**

- Verify current status — check GitHub repos for last commit dates
- Test compatibility — confirm libs work with current Phoenix/Elixir versions
- Multiple sources — cross-reference docs, forums, real usage
- Production focus — prioritize solutions proven in production
- Concrete examples — include code snippets and real calculations

**Critical Checks:**

- Maintenance status — flag any lib not updated in 12+ months
- Breaking changes — note version compatibility issues
- Community health — check issue response times and PR activity
- Documentation — verify comprehensive, up-to-date docs exist

**Output Requirements:**

- Use TodoWrite throughout to track research progress
- Create analysis file: `./codegen/research/{topic}_analysis.md`
- Include research date for future reference
- Provide concrete numbers — setup times, performance metrics, storage calculations
- Real-world examples — show actual impact with calculations

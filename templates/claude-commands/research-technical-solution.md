---
description: Conduct comprehensive technical research and analysis for Phoenix/Elixir solutions
---

Conduct systematic research of technical solutions for Phoenix/Elixir applications, evaluating different approaches across key criteria like setup complexity, performance, maintenance, and production readiness.

**STEP 1: Understanding the Research Topic**

Capture the technical challenge or feature being researched:

- **Core problem** - What technical challenge needs solving
- **Context** - Phoenix/Elixir application specifics
- **Requirements** - Key criteria that matter (performance, compliance, etc.)
- **Constraints** - Budget, timeline, team expertise limitations

Confirm understanding before proceeding with research.

**STEP 2: Research Execution**

First, get the current year using `date +%Y` command to ensure searches include the most recent information.

Use TodoWrite to create and track research tasks, then execute systematic research:

1. **Library/Tool Discovery**

   - Search for Phoenix/Elixir-specific solutions, including current and previous year in queries (e.g., "Phoenix audit log library 2024 2025")
   - Identify popular libraries and patterns
   - Check GitHub activity, maintenance status, last commits
   - Verify compatibility with current Elixir/Phoenix versions

2. **Implementation Approaches**

   - Database-level solutions (triggers, functions)
   - Application-level patterns (contexts, behaviors)
   - Third-party services and integrations
   - Custom implementation strategies

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

For each viable approach, analyze:

- **Setup Complexity** - Time estimates, expertise required, steps involved
- **Code Changes** - Impact on existing codebase with examples
- **Performance Impact** - Concrete metrics, overhead calculations
- **Storage Efficiency** - Real-world calculations and estimates
- **Business Context** - What metadata/context can be captured
- **Gap Risk** - Potential for missing critical operations
- **Maintenance Burden** - Long-term implications

**STEP 4: Create Analysis Document**

Generate a comprehensive markdown analysis with these sections:

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

- **Verify current status** - Always check GitHub repos for last commit dates
- **Test compatibility** - Confirm libraries work with current Phoenix/Elixir versions
- **Multiple sources** - Cross-reference documentation, forums, and real usage
- **Production focus** - Prioritize solutions proven in production
- **Concrete examples** - Include code snippets and real calculations

**Critical Checks:**

- **Maintenance status** - Flag any library not updated in 12+ months
- **Breaking changes** - Note version compatibility issues
- **Community health** - Check issue response times and PR activity
- **Documentation** - Verify comprehensive, up-to-date docs exist

**Output Requirements:**

- **Use TodoWrite** throughout to track research progress
- **Create analysis file** using Write tool: `./codegen/research/{topic}_analysis.md`
- **Include research date** for future reference
- **Provide concrete numbers** - Setup times, performance metrics, storage calculations
- **Real-world examples** - Show actual impact with calculations

This systematic approach ensures thorough evaluation of technical solutions before implementation, reducing risk of choosing deprecated, incompatible, or unsuitable approaches.

The research typically takes 1-3 hours depending on topic complexity, resulting in a comprehensive analysis document that guides implementation decisions.

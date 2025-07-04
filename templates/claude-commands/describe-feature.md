Create a clear, concise feature summary document that can be shared with designers and stakeholders.

This command helps you document a completed or in-progress feature for easy sharing and collaboration.

Steps:

1. **Analyze the current feature** - Review the implementation, understand what has been built
2. **Create a feature summary** - Write a markdown document with exactly these sections:

   - **Summary** - A short paragraph describing what the feature does from a user perspective
   - **Key Features** - Bullet points of main capabilities and functionality
   - **Current UI/UX** - How the feature appears and behaves, organized with subheadings and bullet points

3. **Focus on describing current state** - Write for designers and product managers who need to understand:

   - What the feature currently does for users
   - How users currently interact with it
   - The current visual and behavioral state

4. **Save the document** - MUST create a markdown file named `{FEATURE_NAME}_SUMMARY.md` in the current workspace using the Write tool

5. **Keep it concise** - Aim for 30-50 lines total. Use bullet points, not paragraphs. Be brief and direct.

Critical Requirements:

- **MUST create a file** - Always use the Write tool to create the markdown file, don't just output text
- **ZERO technical details** - NO database, architecture, algorithms, test coverage, code, queries, or any implementation specifics
- **NO "Technical Implementation" section** - Do not include any technical sections at all
- **No checkboxes or completion status** - Write as requirements, not progress reports
- **Describe, don't prescribe** - Document current state, don't suggest design improvements
- **Designer audience only** - Write for people who care about user experience, not code
- **Use the exact format shown** - Summary paragraph, then Key Features bullets, then Current UI/UX with subheadings and bullets
- **Brief and direct** - Keep each bullet point to one short sentence

This summary becomes a useful artifact for:

- Sharing requirements with designers and product managers
- Onboarding new team members to the feature concept
- Planning future iterations or related features
- Documenting decisions and design rationale

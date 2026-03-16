---
description: Suggest a commit message following best practices (50 chars, imperative mood)
argument-hint: [optional context]
---

Analyze the current git changes and suggest ONE perfect commit message following these rules:

1. **Check git status and diff** - Run git commands to see what files have changed
2. **Analyze the changes** - Understand what was added, modified, or removed
3. **Identify the PRIMARY PURPOSE** - Find the main business reason/problem being solved
4. **Focus on the "WHY"** - The commit message should explain why this change was needed
5. **Be SPECIFIC about scope** - Instead of vague terms like "globally" or "system-wide", use precise language like "between projects", "across workspaces", "for mobile users", etc.
6. **Follow commit message best practices**:
   - Use imperative mood (e.g., "Prevent duplicate entries" not "Prevented duplicate entries")
   - Keep under 50 characters
   - Start with a verb (Add, Fix, Update, Remove, Refactor, Prevent, Enable, etc.)
   - Prioritize user/business impact over technical implementation
   - **Economy of words** - Remove filler words, prefer shorter synonyms, cut redundancy

7. **Consider alternative phrasings** - If your first message uses vague terms like "globally", "system-wide", "overall", use more specific alternatives
8. **Suggest ONE perfect message** - The most accurate description of why this change was made
9. **Verify character count** - Run `echo -n "your message" | wc -c` to get the exact count, then display it to confirm it's under 50 characters. Never count manually.
10. **Brief explanation** - One sentence explaining why this message captures the change

If user provided context in the argument, use that to better understand the intent behind the changes.

Examples of "why-focused" commit messages:

- "Prevent duplicate user registrations" (not "Add validation to user model")
- "Fix checkout failures on mobile" (not "Update payment form CSS")
- "Enable offline mode for editors" (not "Add localStorage caching")
- "Prevent data loss during sync" (not "Refactor database transactions")

Examples of SPECIFIC vs VAGUE scope:

- "Prevent port conflicts between projects" (not "Prevent workspace port conflicts globally")
- "Fix login errors for Safari users" (not "Fix authentication issues system-wide")
- "Enable dark mode for mobile app" (not "Add theme support globally")
- "Prevent memory leaks in data sync" (not "Optimize performance across system")

Examples of ECONOMY OF WORDS:

- "Enable job contract negotiation" (not "Enable contract negotiation for job offers")
- "Add user avatar uploads" (not "Add the ability to upload user avatars")
- "Fix cart total calculation" (not "Fix the calculation of the shopping cart total")

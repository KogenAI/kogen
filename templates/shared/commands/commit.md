---
description: Generate and commit with a best-practices message (50 chars, imperative mood)
argument-hint: [optional context]
---

Analyze git changes and suggest ONE perfect commit message.

1. **Check git status and diff** — see what changed
2. **Analyze changes** — what was added, modified, removed
3. **Identify PRIMARY PURPOSE** — main business reason/problem being solved
4. **Focus on "WHY"** — what does this enable or prevent for users? Not "what files did I touch?"
5. **Be SPECIFIC about scope** — "between projects" not "globally"; "for mobile users" not "system-wide"
6. **Commit message rules:**
   - Imperative mood ("Prevent duplicate entries" not "Prevented")
   - Under 50 characters
   - Start with verb (Add, Fix, Update, Remove, Refactor, Prevent, Enable)
   - User/business impact over technical impl
   - Economy of words — remove filler, shorter synonyms, cut redundancy

7. **Consider alternative phrasings** — if first message uses vague terms, use specific alternatives
8. **Suggest ONE perfect message**
9. **Verify character count** — `echo -n "your message" | wc -c`, confirm under 50. Never count manually.
10. **Brief explanation** — one sentence on why this message captures the change
11. **Stage selectively, then commit:**
    - `git status` to see ALL changed files
    - Determine which belong to THIS task
    - All changes belong → `git add -A && git commit -m "[message]"`
    - Some unrelated → stage only relevant files, leave others unstaged, then commit
    - **NEVER add Co-Authored-By trailer**

**If commit already exists:** use `git commit --amend -m "[message]"` instead.

Examples of why-focused messages:

- "Prevent duplicate user registrations" (not "Add validation to user model")
- "Fix checkout failures on mobile" (not "Update payment form CSS")
- "Enable offline mode for editors" (not "Add localStorage caching")

Examples of SPECIFIC vs VAGUE:

- "Prevent port conflicts between projects" (not "globally")
- "Fix login errors for Safari users" (not "system-wide")

Examples of ECONOMY OF WORDS:

- "Enable job contract negotiation" (not "Enable contract negotiation for job offers")
- "Add user avatar uploads" (not "Add the ability to upload user avatars")

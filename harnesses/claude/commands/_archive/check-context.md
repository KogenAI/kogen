---
description: Check for pending work items in the context directory
---

Check for pending work:

1. **List PENDING files:**

   ```bash
   ls ./codegen/context/PENDING-* 2>/dev/null || echo "No pending work found"
   ```

2. **If PENDING files exist:**
   - Read each `PENDING-*.md`
   - Summarize: issue title, priority, target agent, brief description
   - Report total count

3. **If no PENDING files:**
   - Report "No pending work items found"

4. **Output format:**

   ```
   ## Pending Work Items: [count]

   1. **[Issue Title]** (PENDING-filename.md)
      - Priority: [HIGH/MEDIUM/LOW]
      - Target: [agent type]
      - Summary: [one-line description]
   ```

Do NOT automatically start fixing issues — just report what's pending.

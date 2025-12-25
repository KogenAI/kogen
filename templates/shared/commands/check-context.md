---
description: Check for pending work items in the context directory
---

Check for pending work that needs attention:

1. **List PENDING files**:

   ```bash
   ls ./codegen/context/PENDING-* 2>/dev/null || echo "No pending work found"
   ```

2. **If PENDING files exist**:

   - Read each PENDING-\*.md file
   - Summarize: issue title, priority, target agent, and brief description
   - Report total count of pending items

3. **If no PENDING files**:

   - Report "No pending work items found"
   - Optionally mention count of RESOLVED files if relevant

4. **Output format**:

   ```
   ## Pending Work Items: [count]

   1. **[Issue Title]** (PENDING-filename.md)
      - Priority: [HIGH/MEDIUM/LOW]
      - Target: [agent type]
      - Summary: [one-line description]

   [repeat for each]
   ```

Do NOT automatically start fixing issues - just report what's pending.

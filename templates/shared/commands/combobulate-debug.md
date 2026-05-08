---
description: Debug a failed Combobulate build — reads logs, Oban history, and conversation context from the server
argument-hint: [build_job_id, app_id, user_id, or problem description]
---

Debug failed Combobulate build. Read infra docs first:

- `../infra/README.md` — overview
- `../infra/operations.md` — server ops
- `../infra/deploy/platform.md` — platform deployment
- `../infra/setup/databases.md` — PostgreSQL / DB access
- `../infra/setup/environment_variables.md` — env vars

SSH: `ssh root@46.225.1.182`, then `su - combobulate`.

**Parse argument** for any of: build_job_id (UUID), app_id (UUID), user_id (UUID), Oban job ID (integer), error message, or free-text description.

**Steps:**

1. **Read log** at `/home/combobulate/logs/<build_job_id>.log` — show full contents. If no build_job_id, query DB for most recent failed job matching provided app_id or user_id.

2. **Check Oban job history** — query `oban_jobs` where `args->>'build_job_id' = '<id>'`. Report: attempt count, max_attempts, state, inserted_at, attempted_at, discarded_at, errors array.

3. **Find triggering message and conversation** — query messages/conversations for user around job's `inserted_at` (±10 minutes). Show full conversation context with timestamps.

4. **Check retries and follow-ups** — multiple Oban attempts? Follow-up build jobs? Did user send another request?

5. **Determine root cause** — categorize as:
   - Claude asked clarifying question (no `build_result` JSON, `stop_reason: end_turn`)
   - Claude hit runtime error (`{"status":"failed","reason":...}`)
   - Timeout or infrastructure issue
   - Prompt too vague/ambiguous
   - Other (describe)

6. **Check app status** — does app exist in `apps` table? Was it deleted?

**Output:**

```
## Build Debug Report

**Job:** <build_job_id>
**App:** <app_name> (<app_id>) — exists | deleted
**User:** <user_id> (WhatsApp: <phone>)
**Oban:** job <id>, attempt <n>/<max>, state: <state>

### Root Cause
<one paragraph — what went wrong and why>

### Conversation Timeline
<timestamped list of messages around failure>

### Log Summary
<key events — Claude's actions, tools used, cost, stop_reason>

### What Happened After
<follow-up actions by user — retry, delete, abandon?>

### Recommendation
<what to fix to prevent this class of failure>
```

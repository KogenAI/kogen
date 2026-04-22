---
description: Debug a failed Combobulate build — reads logs, Oban history, and conversation context from the server
argument-hint: [build_job_id, app_id, user_id, or problem description]
---

Debug a failed Combobulate build. Before touching the production server, read the infra docs:

- `../infra/README.md` — overview
- `../infra/operations.md` — server ops
- `../infra/deploy/platform.md` — platform deployment
- `../infra/setup/databases.md` — PostgreSQL / DB access
- `../infra/setup/environment_variables.md` — env vars

SSH: `ssh root@46.225.1.182`, then `su - combobulate`.

**Parse the argument** for any of: build_job_id (UUID), app_id (UUID), user_id (UUID), Oban job ID (integer), error message, or free-text problem description.

**Steps:**

1. **Read the log file** at `/home/combobulate/logs/<build_job_id>.log` — show full contents. If no build_job_id was given, query the DB to find the most recent failed job matching the provided app_id or user_id.

2. **Check Oban job history** — query `oban_jobs` where `args->>'build_job_id' = '<id>'`. Report: attempt count, max_attempts, state, inserted_at, attempted_at, discarded_at, errors array.

3. **Find the triggering message and conversation** — query the messages/conversations table for the user around the job's `inserted_at` timestamp (±10 minutes). Show the full conversation context: who said what, in order, with timestamps.

4. **Check for retries and follow-ups** — were there multiple Oban attempts? Follow-up build jobs for the same app after the failure? Did the user send another request?

5. **Determine root cause** — categorize as one of:
   - Claude asked a clarifying question (no `build_result` JSON emitted, `stop_reason: end_turn`)
   - Claude hit a runtime error (`{"status":"failed","reason":...}`)
   - Timeout or infrastructure issue
   - Prompt was too vague / ambiguous
   - Other (describe)

6. **Check app status** — does the app still exist in the `apps` table? Was it deleted?

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
<timestamped list of messages around the failure>

### Log Summary
<key events from the log — Claude's actions, tools used, cost, stop_reason>

### What Happened After
<follow-up actions by the user — retry, delete, abandon?>

### Recommendation
<what should be fixed to prevent this class of failure>
```

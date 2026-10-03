---
title: Land commits with the Intent title as subject
domains: [engine]
size: small
---
Landed commits read `Build <slug>` and carry four trailers: `Kogen-Intent`, `Kogen-Run`, `Kogen-Approval` and `Kogen-Receipt`. The owner wants normal commit messages: the subject is the Intent's title, which is already an imperative summary, and the only trailer is `Kogen-Intent: <slug>`. Runs and approvals are found from the slug, not from the commit.

## Acceptance
- A1: A landed commit's subject line is the Intent's title.
- A2: A landed commit's message has exactly one trailer, `Kogen-Intent: <slug>`, and no other body lines.
- A3: Kogen status still reports the Intent as landed with the landed commit.

## Verify
- A1: test domain=engine
- A2: test domain=engine
- A3: test keep domain=engine

## Notes
Update the existing e2e assertions about the old trailers. The approval commits on `refs/kogen/intents/<slug>` keep their own trailers; this Intent changes only the landed commit.

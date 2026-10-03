---
title: Build approved Intents on a moved base
domains: [engine, docs]
size: small
---
An approval records the base commit it was made on, and a Build refuses to start once the base branch has moved. A queue of approved Intents can therefore land only its first one, unless each is re-approved, which makes approvals meaningless. Let a Build start on the current tip when the approval still holds there.

## Acceptance
- A1: An approved Intent whose base gained an unrelated commit before the Build starts is built and landed without a new approval.
- A2: An approved Intent whose approved acceptance test changed on the base after approval is refused with a reason naming that file.
- A3: An approved Intent whose base did not move is built and landed as before.

## Verify
- A1: test domain=engine
- A2: test domain=engine
- A3: test keep domain=engine

## Notes
The approval still holds on the current tip when the approved base is an ancestor of the tip and every file in the approval's protected manifest is unchanged between the approved base and the tip. The Build then starts from the tip; red-on-base already runs on the Build's checkout. Keep this check in the engine's start path, where the exact-base refusal is today.

---
title: Show why an approval check failed
domains: [kernel]
size: small
---
When an acceptance check fails, `kogen approve` prints only `acceptance check compile failed`. The Shaper then has to rerun the command by hand to see the compiler or Credo message. Print the failing check's output tail with the failure.

## Acceptance
- A1: When an acceptance check fails, `kogen approve` prints the last lines of that check's output.
- A2: When an acceptance check times out, `kogen approve` names the check and says it timed out.

## Verify
- A1: test domain=kernel
- A2: test domain=kernel

## Notes
Keep the printed tail bounded (about 2 KB), like other failure details.

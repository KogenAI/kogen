---
title: Stop when the same scope edit repeats
domains: [build]
size: small
---
Three Builds tonight failed the same way. The Developer needed a file outside the Intent's domains, the scope guard refused it, and every repair edited the same file again until the repair cap. A repeated, identical scope violation means the Intent's scope is wrong, not the code. Stop the Build at the second identical scope failure with a reason that tells the Shaper to widen the scope.

## Acceptance
- A1: A second scope-edit failure with the same detail fails the Build with reason `scope_needs_widening` instead of repairing.
- A2: A second scope-edit failure with a different detail still gets a repair.
- A3: A first scope-edit failure gets a repair.

## Verify
- A1: test domain=build
- A2: test keep domain=build
- A3: test keep domain=build

## Notes
The failure detail names the out-of-scope paths, so comparing details is enough. Keep the detail in the finished result so the report shows which paths need a domain.

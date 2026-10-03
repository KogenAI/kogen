---
title: A green rerun of the done gate advances
domains: [build]
size: small
---
When the done gate fails on a flaky test, the Cycle sends the Developer back with a repair. If the Developer finds nothing to change and the gate now passes, the Cycle fails the Build as `unchanged`, discarding a good candidate. This happened on a real self-build. After a done-gate repair, let an unchanged tree go back to the done gate, whose new result decides.

## Acceptance
- A1: After a done-gate repair, a develop result with the unchanged tree advances to the done gate, and a passing gate then advances to fix.
- A2: After done-gate repairs on an unchanged tree, a red gate at the repair cap fails the Build with `repair_cap`.
- A3: After a red check repair, a develop result with the unchanged tree still fails the Build as `unchanged`.

## Verify
- A1: test domain=build
- A2: test domain=build
- A3: test keep domain=build

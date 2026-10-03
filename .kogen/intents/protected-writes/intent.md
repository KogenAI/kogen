---
title: Refuse tool writes to protected files
domains: [harness, kernel]
size: small
---
A Developer on ElixirDrops edited the approved acceptance test with the `edit` tool to make it stricter. The edit succeeded and was caught only at the done gate, so the same edit failed the Build three times and used up both repairs. Refuse such writes at the tool, with an error the Developer can act on.

## Acceptance
- A1: `edit` and `write` on a path listed in Harness `protected` return an error naming the path and leave the file unchanged.
- A2: An `edit` tool call on a path not listed in `protected` still changes the file.
- A3: The `protected` field defaults to an empty list.

## Verify
- A1: test domain=harness
- A2: test keep domain=harness
- A3: test domain=harness

## Notes
`protected` holds exact worktree-relative paths. The Build passes the paths of the approval's protected manifest (which includes the approved acceptance tests). The error text should tell the Developer the file is approved and protected, and that it must change the implementation instead. Shell commands are still caught by the gate as today.

---
title: Show the reviewer the whole change
domains: [engine, workspace, harness, docs]
size: small
---
The reviewer gets `git diff <base>` of the Candidate, which leaves out files the Developer added, and only the last 16 KB of that diff survives. A new module, or the start of a large change, is invisible to review. Give the reviewer the full change, new files included, and mark any cut explicitly.

## Acceptance
- A1: The review request contains the content of a file the Developer added.
- A2: The review request contains the start of a change larger than 16 KB.
- A3: The review request still contains edits to existing files.

## Verify
- A1: test domain=engine
- A2: test domain=engine
- A3: test keep domain=engine

## Notes
Add a Workspace function that diffs the Candidate's full tree against the base through Workspace's existing private index (`with_private_index`, as `tree_hash` does), so new files are included without touching the real index or building git env maps outside Workspace. The engine reads the whole diff, not the 16 KB output tail. The harness review prompt currently cuts the diff to its first 20,000 characters (`Kogen.Harness.Stages`). Raise that cap to at least 200 KB and end any cut with a visible truncation marker.

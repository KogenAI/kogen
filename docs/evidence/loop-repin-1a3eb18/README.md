# Re-pin kogen-loop to 1a3eb18

Synced with `sh packaging/sync-kogen-loop.sh` from a clean kogen-loop checkout at
1a3eb18f2675d3cbb6f3220ea4cfc7cd9e9f49aa: 169 files, digest
2eb14127c252aec7b7d1d459f792e4ea4fd7f627320bc5f2cc6f8c1e2422de89.

New since 8a2fcda:
- 733b50d: independent streamed tool calls run concurrently when no hooks are set; results
  keep their original order.
- 99d858a: a shell call no longer waits without bound; the command keeps running.
- b998f2a: a retried 429 or 503 with Retry-After waits the advertised time, up to 60 s.
- 98a02ab: shell tool results are valid UTF-8 at every size.
- 07f21da: a request over the budget is condensed instead of refused.
- 6b82843: the default instructions tell the agent to finish as soon as its checks pass.
- 1a3eb18: later loop changes are recorded in the commit history, not CHANGELOG.md.

The vendored copy is a protected path and changes only through the sync script.

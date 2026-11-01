# Re-pin kogen-loop to af456d5

Synced with `sh packaging/sync-kogen-loop.sh` from a clean kogen-loop checkout at
af456d56c52e9e8a012bff8ca1b88e2df1990cf8: 170 files, digest
95d729d274dba01ec25dbc0dc83a92e2975660ece5ea157b7bcf7e329bfed4e5.

New since 1a3eb18:
- 262e88d: a streamed attempt with runaway visible output ends instead of running on.
- 4ed1bf1, c013f25, 9402b2d: kogen-loop's own conformance, provider, sys, tools and loop tests
  run in parallel where they are independent.
- af456d5: retrieving a running shell command by its handle waits up to 30 seconds and returns
  as soon as the command completes, so a long command no longer costs one model request per
  second of waiting. A new command still yields after one second; nothing is killed by the wait.

The vendored copy is a protected path and changes only through the sync script.

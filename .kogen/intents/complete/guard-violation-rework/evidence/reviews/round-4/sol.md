## Findings

- [BLOCKING] Environment-event reset is underspecified: `GuardedPaths.check/2` is required to return only `{:ok, env_events}` while also resetting the immutable snapshot; the current caller has no state-update path, so the same event can recur every handoff. — `INTENT.md:28-31`; `lib/kogen/build.ex:1278-1281`; `lib/kogen/build/guarded_paths.ex:52-68` — Return a refreshed snapshot (or define an explicit reset caller), thread it through all handoff paths, and assert the next handoff emits no duplicate event.

- [BLOCKING] The shared-git scenario never creates a new nonvolatile Candidate file matching the added exclude rule, yet requires the ignored-file manifest to report it. Existing ignored `deps/` and `_build/` content is volatile-filtered. — `scenarios.yaml:84-95`; `lib/kogen/build/guarded_paths.ex:91-102,176-180`; `test/support/workspace_fixture.ex:153-159` — Create a matching Candidate file after changing `.git/info/exclude` and assert its path is reported.

- [BLOCKING] `guard_violations` must appear in the Review packet, but the existing packet contract has an exact top-level key set and its test is outside `may_change_guarded_paths`; the Draft does not specify a backward-compatible location. — `scenarios.yaml:116-127`; `intent.yaml:19-32`; `lib/kogen/build/review_packet.ex:24-26,184-206`; `test/kogen/review_packet_test.exs:15-30` — Specify and test a nested/backward-compatible field, or include/update the packet test and ledger.

## Verdict: not ready
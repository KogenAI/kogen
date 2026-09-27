## Findings

- **[BLOCKING]** The provider-retry case cannot follow the specified path when the failed rework turn still leaves `stray.txt`: transport failure checks `post_developer_inputs_unchanged/1` first, and retries only on `:ok`; a remaining guard violation prevents `retry_developer/5`. The scenario nevertheless requires that exact turn to retry with the guard prompt — `scenarios.yaml:13-26` — `lib/kogen/build.ex:1218-1247,1251-1261` — define precedence for provider markers versus guard violations, preserve the rework prompt/session, and test it.

- **[BLOCKING]** `guard_violations` has no bounded packet representation. `ReviewPacket` is capped at 65,536 bytes, while its profiles cap only notes, receipts, handoff, and findings; a large changed-path list can make Review packet construction fail or violate the requirement that all reverted paths remain visible — `INTENT.md:35-39` — `lib/kogen/build/review_packet.ex:20-35,174-207` — add a bounded structured field with digest/locator stubs and an oversized-list offline case.

- **[ADVISORY]** Tracked mode-only restoration is claimed but not proven. The prompt specifies `git show` and only vaguely mentions `chmod`; the fake/scenario exercises byte restoration of `README.md`, while the guard explicitly detects executable-bit changes — `INTENT.md:21-27` — `scenarios.yaml:23-25` — `test/kogen/guarded_paths_test.exs:13-39` — provide the exact mode-restoration instruction and a mode-only fake case.

- **[ADVISORY]** The audit citation is stale: `questions.md` still cites shaping-quality lines `352-353` and the deleted refresh script, while current shaping-quality defines `ledger-row-update-unstated` at `scenarios.yaml:360-370`; `references.yaml` also omits lesson 22 — `questions.md:68-71` — update the disposition and references.

## Verdict: not ready
# Audit dispositions (2026-09-25)

Sol = GPT-6 Sol high; Astra = GPT-6 Astra medium. Both ran read-only.

| Finding | Disposition |
|---|---|
| Sol 1: the parent controller runs old code | Accepted as a clarification. Proof comes from check plus the nested fixture Build, which runs Candidate code (INTENT "Self-hosting and where proof comes from"). |
| Sol 2 / approval state | The package moves to `approved/` with its approval recorded before Build. |
| Sol 3, Astra 4: packet and sidecar integrity unbound | Fixed. Packet and sidecar digests are kept in controller state and verified before and after Review and at publication, with mutation stops. |
| Sol 4: raw stream references are not proof of reading | Fixed. The audit requires a tool call whose input names the packet path, and the accepting verdict must cite a Candidate file. |
| Sol 5: packet format underspecified | Fixed. Canonical JSON, fixed keys, per-field caps, the truncation record shape, an `omitted` list, and fail-closed instead of dropping ids. |
| Sol 6: sidecar not in resolve or publication | Fixed. `verify_reference/3`, `Evidence.resolve/2` and the publication check all validate sidecars. |
| Sol 7: fixture cleanup loses artifacts | Fixed. Packets, sidecars, the complete package and the audit summary are retained in the log directory. |
| Sol 8, Astra 7: temp path, login and trust | Fixed. Canonical realpath; a login-scope preflight before dispatch. Today's fixture paths are already new per run, so scope selection is unchanged in kind. |
| Sol 9: callers and consumers | Fixed. `tracking_path` stays in the Reviewer context, so the fake consumers keep working. A new `review_packet_audit.ex`; the shared `live_rework_audit.ex` is not modified, so live-shape-to-build is not dragged in. The ledger is added to affected paths. |
| Sol 10, Astra 10: planted defect through the packet route | The live first Review's planted omission is the real control, and the scenario now states it. Offline controls stay unweakened. |
| Sol 11, Astra 6: cross-attempt control | Fixed. Same attempt_token and session, final passing Candidate equals the settled one, and an explicit cross-attempt negative case. |
| Sol 12, Astra 5: Codex claim | Narrowed to argument construction for every role and helper; the provider effect is proved in the next Intent. |
| Sol 13, Astra 8: timing | Per-Review elapsed time is retained with no threshold. Timeouts are unchanged by rule. |
| Astra 1: selectors do not exist yet | By design: the Developer creates them; missing means unfinished work (README). |
| Astra 2: ledger | Added to affected paths and guarded paths. |
| Astra 9: scope | Kept as one Intent; see INTENT "Why this is one Intent". |

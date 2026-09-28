# Probe: where a Codex session records its working directory (2026-09-25)

Question: can a live test read, from the Kogen-managed Codex session store,
the directory a real auditor session ran in? The `live-native` case in
scenario `real-auditor-on-adversarial-harness` depends on it.

Method (read-only, no provider call, no Codex launch): read one existing
session file of the shared Kogen Codex scope,
`~/Library/Application Support/Kogen/codex/accounts/shared/sessions/2026/09/24/rollout-2026-09-24T10-20-19-01a0d249-6152-7542-95ca-b8ba913a2f80.jsonl`
(Codex 0.156.1, written by a Kogen launch on 2026-09-24).

Observed: every `turn_context` line carries `payload.cwd` next to `model`
and `effort`, for example:

```
"type":"turn_context","payload":{"turn_id":"01a0d249-640f-7951-b971-34447fd72000",...,"cwd":"/Users/almirsarajcic/Areas/Kogen/kogen","workspace_roots":["/Users/almirsarajcic/Areas/Kogen/kogen"],...,"approval_policy":"never",...,"sandbox_policy":{"type":"danger-full-access"...
```

`cross-harness-adversarial-roles` already reads `turn_context.payload.model`
and `payload.effort` from the same file to prove the executed identity
(`test/kogen/native_helper_live_test.exs`, hybrid Expert case, in its
Candidate). The auditor receipt can read `payload.cwd` the same way.

Limitations: this session ran in a trusted project (Kogen's own checkout).
Whether managed Codex 0.156.1 runs a turn at all when its working directory
is a git repository outside every trusted project is not observable here.
That is the provider-only observation the `live-native` case exists for. The
`sandbox_policy` `danger-full-access` confirms that a Codex role session is
not sandboxed, so read-only must be enforced by detection.

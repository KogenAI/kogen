# Pinned Codex root-routing probe

The executable probe is retained as `runtime_probe.exs`. It created a linked Candidate and independent repository with distinct instructions/sentinels, opened the installed managed Codex selection with the Candidate as `project`, and launched a fresh Developer with exactly one explorer helper, exact-session resume, and fresh Reviewer.

Two invalid prerequisite attempts using `/usr/bin/python3` stopped before provider dispatch with `Python 3.11 or newer is required`; both cleaned their disposable roots. A third attempt reached native Codex without the Build verification-policy environment; the tracked PreToolUse hook correctly blocked shell commands because required targets were missing. That run was interrupted after the limitation was observed, and its exact worktree/branch/temp root were explicitly removed. These attempts do not support runtime-root claims.

The corrected authenticated command was:

```sh
PATH="/Users/almirsarajcic/.local/share/mise/installs/python/3.14.7/bin:$PATH" \
  mix run .kogen/intents/drafts/isolated-candidate-workspace/evidence/runtime_probe.exs
```

Corrected fresh result, preserving the final agent message verbatim:

```text
- `pwd` exact output: `/Users/almirsarajcic/Areas/Kogen/kogen`
- `git rev-parse --show-toplevel` exact output: `/Users/almirsarajcic/Areas/Kogen/kogen`
- `candidate-sentinel.txt`: does not exist; therefore no token is present.
- Applicable repository instruction token: none. No `AGENTS.md` exists in the repository’s ancestor chain.
- Independent-repository token visible: no.

Explorer helper independently reported:

- `pwd`: `/Users/almirsarajcic/Areas/Kogen/kogen`
- Git root: `/Users/almirsarajcic/Areas/Kogen/kogen`
- Applicable instruction token: none; no applicable `AGENTS.md` was found.

No files were modified.

ROOT_PROBE_FRESH
```

The exact-session resume reused session `01a0bb0a-6c51-7b93-a5b2-9877cd265ef4` and returned:

```text
- `pwd`: `/Users/almirsarajcic/Areas/Kogen/kogen`
- Git root: `/Users/almirsarajcic/Areas/Kogen/kogen`
- `candidate-sentinel.txt`: does not exist; no sentinel token.
- Applicable repository instruction token: none; no applicable `AGENTS.md` was found.
- No files were edited.

ROOT_PROBE_RESUME
```

The fresh Reviewer session `01a0bb0f-8e02-7d40-85e0-1412c19f2a01` returned a schema-valid accepting reason claiming control `pwd`/Git root but Candidate sentinel and instruction tokens. Because its retained result did not include command events, those token claims are not proof of physical reads; the internal contradiction is a negative control against accepting role prose without target-owned command evidence.

Cleanup reported `CLEANUP_EXISTS=false`. Conclusion: the pinned runtime's fresh Developer, helper, and exact resume inherit the control cwd despite `Kogen.Codex.open(config, candidate)` and Candidate trust configuration. Explicit execution-root propagation is required. Reviewer evidence must separately prove command cwd/Git root and sentinel reads.


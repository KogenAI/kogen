# Questions and choices

No open questions.

## Assumed

1. Keep `Workspace.canonical/1` on top of the shared function; its callers are unchanged.
   Reason: removing it breaks unguarded callers (review round 1); it is shared code, not a deprecated path (rule 44).
   Undo: inline the shared function into Workspace and delete ProjectScope.
2. No legacy-selector detection and no auth change.
   Reason: every real caller already passes a physical path (`File.cwd!()`, Build canonicalizes), so no id changes.
   Undo: add a selector check in ClaudeCode/Codex.State scope selection.

## Audit

- Round 1 (Astra, Sol, Opus): not ready → shrunk (keep Workspace.canonical, no auth change, symlink fixture).
- Round 2 at 82ac4351: Astra ready, Opus ready (advisories adopted: title ≤50, Reason/Undo, independent expected path,
  WorkspaceFixture.tmp_dir!, citation), Sol not ready (Workspace.canonical/1 not exercised) → added. Sol re-runs.

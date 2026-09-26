# Key project scopes by the checkout's canonical path

## Why

Three copies of `project_id/1` hash `Path.expand(root)` (`Kogen.ClaudeCode.project_id/1`, `lib/kogen/claude_code.ex:242-243` at 82ac4351;
`lib/kogen/codex/state.ex:7-8`, `lib/kogen/build/workspace.ex:49-50`) while `Workspace.canonical/1`
(`workspace.ex:92-101`) resolves realpath. Today every writer happens to pass a physical path (login `File.cwd!()`,
Build canonicalizes the control path, `build.ex:133-143`), so ids agree by accident; any caller passing a symlinked
spelling (`/tmp/X` vs `/private/tmp/X`) would pick a different login scope and workspace root.

## Outcome

- A zero-dependency boundary module `Kogen.ProjectScope` exposes `canonical/1`: realpath of the nearest existing
  ancestor with the missing tail appended (so a not-yet-created path under a symlinked parent gets the id it will have
  once created); `Workspace.canonical/1` is implemented on it (shared code, not a deprecated path: its callers are
  unchanged). All three `project_id/1` hash `Kogen.ProjectScope.canonical/1`; `Kogen.ClaudeCode`, `Kogen.Codex` and
  `Kogen.Build` add it to their Boundary deps. Workspace docs say "canonical control path".
- Every id a real caller produces today is unchanged (they already pass physical paths), so no login is affected and
  the auth model does not change (DIRECTION D1, rule 24).

- `Workspace.canonical/1` changes behaviour only for paths that do not exist yet (nearest existing ancestor + tail instead
  of `Path.expand/1`); no caller breaks; its docs (`workspace.ex:11-12,45-46,52,90`) are updated in this Build.

## Non-goals

- Any selector migration or new error (no real caller can produce a legacy selector, review round 1).

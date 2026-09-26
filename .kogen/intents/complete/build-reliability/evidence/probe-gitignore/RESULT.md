# Probe: `.gitignore` as an ordinary guarded file (2026-09-26, clone of main 7ed41f66)

The patch removed `.gitignore` from `GuardedPaths.config_files/1` (frozen config),
leaving `.git/config`, `.git/info/exclude` and `.gitmodules` frozen. It then
captured a fixture repository and ran `GuardedPaths.check/2` (`probe.exs`,
`result.txt`).

| Candidate change | Guards | Result |
|---|---|---|
| `.gitignore` adds `hidden.txt`, and writes `hidden.txt` | `[]` | error: `.gitignore, hidden.txt` |
| same | `[".gitignore"]` | error: `hidden.txt`. The hiding attempt is still caught by the frozen ignored manifest. |
| same | `[".gitignore", "hidden.txt"]` | `:ok` |
| `.gitignore` adds `*.pid` only | `[".gitignore"]` | `:ok` |
| same | `[]` | error: `.gitignore` |

**Conclusion:** the frozen ignored manifest (`ignored_manifest/1`,
`guarded_paths.ex:115-135`) already catches files hidden by a new ignore rule. So
`.gitignore` can safely be an ordinary tracked, guarded file. The clone was
reverted.

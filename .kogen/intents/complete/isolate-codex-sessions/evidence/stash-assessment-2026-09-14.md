> Historical pre-approval observation from this visit. Current approval is owned
> by [the September 14 statement](approval-2026-09-14.md); observations and limits
> below are preserved as recorded.

# Latest Isolation stash assessment

The Shaper asked to inspect stashes and recommend reuse versus starting from
scratch. This records a recommendation, not accepted reuse, baseline adoption,
approval, implementation permission or a Build launch.

Read-only Git inspection found:

- Latest named Isolation: stash@{1} at inspection, immutable commit
  e3d993f38fe6ef8fe97ea17eb4e9d2f2b92056c7, September 14 07:07:30 +0300.
  Base 2890d86f16c8819cfad12cbd98dbbdc8ee068b1c; 58 changed files,
  5667 added / 67 removed lines. Both stash parents are tracked snapshots;
  no separate untracked-files parent is present.
- Newer stash@{0}, “Reconnect thing”, is
  efdb5a16814439c6c1860ad4ed9da3ed29e2dc4e, September 14 09:51:58 +0300,
  on the same base. It does not contain lib/kogen/codex.ex and is not a
  cumulative newer Isolation snapshot. Its 16 changed files include broader
  provider recovery and Reviewer resume, beyond this Intent's bounded stream
  classification requirement. Do not combine the stashes indiscriminately.
- Current clean HEAD is now d3a1582c. Compared with the visit-start 9a8e7eba,
  only four Complete bound-build-evidence files differ; this is an observed
  later checkout, not a replacement for the supplied visit metadata.
- Nineteen Isolation paths overlap newer main. Read-only command
  `git diff --binary 'stash@{1}^1' 'stash@{1}' | git apply --check`
  fails on eleven paths, including check.sh, Build, Harness, semantic live setup,
  verification fixtures and shaping driver. A check failure establishes that the
  patch is not directly applicable; it does not predict every three-way conflict.
  No apply, pop, reset, checkout, source write or test was performed.

## Recommendation

Use a fresh Build rooted in current main and treat the immutable Isolation stash
as selective implementation input. Reuse the installer, state/account selection,
private environment/executor code and focused tests where inspection supports it.
Reintegrate shared launch/Build/hooks and live fixture consumers against current
schema-bound handoffs, unified Stop verification, seven-case evaluation and compact
publication. Rewriting every module discards useful work; wholesale stash restoration
risks bringing obsolete integration assumptions back.

There are real partial repairs worth retaining: stash live_test.exs:289-290 copies
its environment.py hook dependency, and managed_resume.py preserves the outer role.
The helper configuration in environment.ex:184-188 and :364-365 still uses profile
TOML plus inline agents.<role>.config_file; it is not the demonstrated standalone
agent discovery repair. Native event correlation and reconnect parser repair are
not present in this Isolation snapshot. Historical passing native evidence remains
source-bound; no current complete acceptance or stash correctness is established.

Root inspected stash identities, base/overlap, actual launch and selected module
bytes and patch applicability. The configured read-only scout supplied a bounded
repair inventory. Root rejected its claim that the original semantic fixture still
omits environment.py after checking the actual stash bytes. No private logs copied.

The existing no-wholesale-restoration decision remains intact. The selective reuse
recommendation has not yet been adopted by the Shaper. This is the same shaping
visit, with no additional continuation or approval record.

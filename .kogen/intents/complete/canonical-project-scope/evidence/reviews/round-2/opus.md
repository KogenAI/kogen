## Findings

**Round-1 blockers are all resolved at 82ac4351:**
- `Workspace.canonical/1` stays, rebuilt on the shared function (`INTENT.md:15`). Its unguarded callers keep compiling: `lib/mix/tasks/kogen.expert.ex:132`, `test/support/workspace_fixture.ex:113`, `build_workspace_test.exs:103,110,200`, `harness_role_test.exs:166,326`.
- The fixture now lives under `System.tmp_dir!()` with an explicit `File.ln_s` alias (`scenarios.yaml:4-6`). That proof isn't trivial inside a Build, where TMPDIR is already physical.
- The legacy-selector error and the auth change are gone, so D1 isn't triggered.
- The Codex fake-path gap is moot: no scenario goes through `bind`/`open`.

**Checks that pass:**
- The guarded paths cover every Boundary owner. `Codex.State` sits under `Kogen.Codex` (`codex.ex:7`) and `Workspace` under `Kogen.Build` (`build.ex:42-53`).
- `Workspace.project_id` (`workspace.ex:49-50`) and `Workspace.canonical` (`workspace.ex:92-101`) match. `Codex.State.project_id` (`state.ex:7-8`) and `build.ex:133-143` match too.
- `project_scope_test.exs` passes the proof-selector check before it exists, because it's in `affected_paths` (`verification_plan.ex:536-537`).
- New test files are left out of the ledger (`ledger.ex:9`). The reliability catalog has no `source_sha256` binding (`test_reliability_catalog_test.exs:19`).
- The four "unedited" tests don't depend on the old formula. They derive ids through the same functions, so changing both sides together keeps them green.

**Findings:**

- [ADVISORY] **Stale citation.** At 82ac4351, `project_id/1` in `claude_code.ex` is at lines 242-243; lines 238-239 are `scope/2`. — `INTENT.md:5` — Re-cite, and re-anchor again after shaping-quality lands, since it also edits `claude_code.ex`, `codex.ex` and `build.ex` (shaping-quality `intent.yaml:313-316`).

- [ADVISORY → blocking in shaping-quality's audit] **Title too long.** The title is 51 characters, and the mechanical `title-format` check allows at most 50. That finding can't be disputed. — `intent.yaml:3`; shaping-quality `scenarios.yaml:366-369` — Use e.g. "Key project scopes by canonical checkout path".

- [ADVISORY → blocking in shaping-quality's audit] **Assumptions lack `Reason:`/`Undo:`.** The two `## Assumed` entries have neither, which raises `assumption-without-reason`. — `questions.md:7-8`; shaping-quality `scenarios.yaml:55` — Add both lines to each entry.

- [ADVISORY] **The "no login changes" claim is asserted, not proven.** It rests on `File.cwd!()` returning the symlink-free path. Scenario 2 only checks an already-canonical path against the old formula, which is true by construction. Only an unguarded test comment backs the claim today (`candidates_command_test.exs:433-437`). — `scenarios.yaml:19-27` — In `project_scope_test.exs`, `File.cd!` into the alias and assert `File.cwd!()` equals the realpath. That's the actual path login uses (`claude_code.ex:342`, `codex.ex:253`).

- [ADVISORY] **Scenario 1 could pass without testing anything.** If the expected id is computed with `ProjectScope.canonical/1` itself, the test checks the function against itself. — `scenarios.yaml:8-10` — Name an independent expected value, e.g. `File.cd!(real, &File.cwd!/0)` or the `/bin/realpath` output.

- [ADVISORY] **Scenario 2's fixture isn't pinned.** Outside a Build, a raw `System.tmp_dir!()` path on macOS contains the `/var` symlink. The assertion then differs from the old formula and fails on a developer's `mix test`, even though it passes inside a Build. — `scenarios.yaml:20` — Require `WorkspaceFixture.tmp_dir!/1` (`workspace_fixture.ex:105-114`), which returns the canonical path.

- [ADVISORY] **`Workspace.canonical/1` changes for missing paths.** It currently falls back to the expanded path (`workspace.ex:90,97`). No caller breaks, but two things go stale:
  - the docs at `workspace.ex:11-12,45-46,52,90`, which are guarded and should be updated in this Build;
  - the comment at `candidates_command_test.exs:451-455`, which is unguarded, so it stays wrong unless it's added to the guarded paths.
  
  — Say this in INTENT.md.

## Verdict: ready

Nothing I found would make the Build fail or deliver the wrong outcome. The title and `## Assumed` fixes are one-line edits. They're needed before the Draft can pass shaping-quality's audit once that lands.

The session asked me to write a plan file, but I had no write tool, so nothing was written. The Stripe connector also needs authorizing in claude.ai's connector settings before it can be used; this review didn't need it.

# Re-baseline on main 7ed41f66 (isolated-candidate-workspace landed), 2026-09-26

**Lazy-loading hazard (lesson 17): closed for Builds**
- The Candidate is its own worktree, with a plain `deps/` copy and no `_build/`
  (`lib/kogen/build/workspace.ex:16-18`).
- `VerificationRunner` scrubs `MIX_BUILD_PATH`, `MIX_DEPS_PATH` and `MIX_EXS`
  (`verification_runner.ex:17-20`), so the controller-run `make check` compiles
  into the Candidate's own `_build/`.
- The Seatbelt write boundary denies every role write to control
  (`write_boundary.ex`; `write_boundary_test.exs`).
- Executed on a clone of 7ed41f66 (`iso-tests.txt`), 2 passed:

      mix test test/kogen/candidate_verification_test.exs:221 test/kogen/build_workspace_test.exs:155

  - `…:221` asserts that control's `_build/` "must gain nothing from the
    Candidate's own mix compile".
  - `…:155` asserts that the Candidate has no `_build/`.
- **Residual:** a compile run in the control checkout itself during a Build (by
  the human or a Shaping session). That is an outside writer, and
  `pinned-engine-generations` closes it.
- So this Build needs no preload and no prerequisite Intent, and it is launched
  with the plain command.

**Verdict schema probes re-run through 7ed41f66's launch path** (`run-7ed41f66/`)
- One lookaround-free schema, shared by both harnesses.
- **Claude:** launch and `--resume` passed, with the same session and verdict.
- **Codex:** launch passed (98 s) and `exec resume` passed, with the same thread
  and verdict.
- Both resisted the adversarial control, and `receipt` was null.

**Anchors** (`rebaseline-7ed41f66.md`)
- These hold: `offline.py`, `rehearsals.exs`, `driver.py` (zero diff),
  `FailureSignature`, `Verdict` (static schema, bare `:error`),
  `Contract.verdict/4` exact keys, and the absence of any `resume_reviewer`.
- These moved: `verification_failure_prompt/3` is now `build.ex:830-869`, and
  `run_cycle` is now around `verification.ex:165-260`.
- **Design changes:**
  - `prepare` runs through `VerificationRunner`: cwd is the Candidate worktree,
    with a scrubbed environment, its own process group and a controller-owned log.
  - The `live-reviewer-rework` nested Build now runs in an isolated worktree,
    under a Codex write boundary and a harness home.
- **Correction:** defect (d), the canonical scope key, was **not** fixed by
  isolated-candidate-workspace. `project_id/1` still hashes `Path.expand`
  (`claude_code.ex:238`, `codex/state.ex:7-8`). It is still open, with no owner.

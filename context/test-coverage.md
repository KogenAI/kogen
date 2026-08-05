# Test Coverage Inventory

Enumerates every executable surface in the codegen repo and names the test that exercises it. Empty `Test` cells are work items for later pitch stages.

Source of truth for the test-coverage-everything pitch (the ready-pitch file for test-coverage-everything). Updated by context curator as tests are added.

Columns:

- **Surface** — short name
- **Type** — launcher | generator | install | extension | mutation | hook | hook-lib | exunit | shared-lib | make-target
- **File/Path** — where the surface lives
- **Test that exercises it** — file path or "—" (no test)
- **Notes** — stage that owns adding the test, or special remarks

### Section 1 — Harness × Mode Launchers

| Surface                | Type       | File/Path                                    | Test that exercises it                                                                                                                       | Notes                                                                          |
| ---------------------- | ---------- | -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| claude-build           | launcher   | `harnesses/claude/claude-build.sh`           | `test_harness/test/stacks/phoenix/{scaffold,seed,gate,committer,iteration}_test.exs`; `test_harness/test/stacks/static/{iteration}_test.exs` | All 11 ExUnit cases use `codegen-build` → `claude-build` when `HARNESS=claude` |
| claude-debug           | launcher   | `harnesses/claude/claude-debug.sh`           | `test_harness/test/stacks/modes/debug_test.exs`                                                                                              | Stage 4 (HARNESS=claude)                                                       |
| claude-shape           | launcher   | `harnesses/claude/claude-shape.sh`           | `test_harness/test/stacks/modes/shape_test.exs`; `harnesses/claude/hooks/portable-launcher_test.sh` (Tier-0/Tier-1 selection)                | Stage 4 (HARNESS=claude)                                                       |
| claude-experiment      | launcher   | `harnesses/claude/claude-experiment.sh`      | `harnesses/claude/hooks/portable-launcher_test.sh` (Tier-0/Tier-1 selection)                                                                 | No dedicated ExUnit stage case                                                 |
| pitch-context-selector | shared-lib | `harnesses/shared/pitch-context-selector.sh` | `harnesses/claude/hooks/portable-launcher_test.sh` (citation priority, cited-only, keyword-only, cap warning, missing-file error)            | Sourced by the shape/experiment launchers                                    |
| claude dispatch        | launcher   | `harnesses/claude/dispatch.sh`               | `harnesses/claude/hooks/dispatch_test.sh`; `harnesses/claude/hooks/codegen-build_test.sh` (via `make harness-parity`)                        | Stubs validated; runtime path indirect via ExUnit                              |
| loop-signal-bridge     | shared-lib | `harnesses/shared/loop-signal-bridge.sh`     | `harnesses/shared/loop-signal-bridge_test.sh` (direct-call + foreground-PTY cases); auto-discovered via `harness-parity`'s `*_test.sh` glob  | Sourced by dispatch.sh + the build launcher's `--queue` leg        |
| codegen-build entry    | launcher   | `codegen-build` (repo root)                  | `harnesses/claude/hooks/codegen-build_test.sh` (via `make harness-parity`); 11 ExUnit cases                                                  | Top-level harness API; fails if the gate-result JSON is missing    |
| codegen-scaffold entry | launcher   | `codegen-scaffold` (repo root)               | Exercised by `shared/scaffold/static/scaffold_test.sh` (via `make test`)                                                                     | No dedicated test                                                              |
| codegen-call entry     | launcher   | `codegen-call` (repo root)                   | `harnesses/claude/hooks/codegen-call_test.sh` (via `make test`)                                                                              | One-shot structured LLM call binary                                            |
| call-dispatch          | launcher   | `harnesses/claude/call-dispatch.sh`          | `harnesses/claude/hooks/call-dispatch_test.sh` (via `make test`)                                                                             | Dispatcher for codegen-call invocations                                        |

### Section 2 — Stacks (ExUnit dimension)

| Surface                         | Type   | File/Path                                             | Test that exercises it                                                      | Notes |
| ------------------------------- | ------ | ----------------------------------------------------- | --------------------------------------------------------------------------- | ----- |
| Phoenix scaffold                | exunit | `test_harness/test/stacks/phoenix/scaffold_test.exs`  | self (1 test)                                                               |       |
| Phoenix seed                    | exunit | `test_harness/test/stacks/phoenix/seed_test.exs`      | self (1 test)                                                               |       |
| Phoenix gate                    | exunit | `test_harness/test/stacks/phoenix/gate_test.exs`      | self (1 test)                                                               |       |
| Phoenix committer               | exunit | `test_harness/test/stacks/phoenix/committer_test.exs` | self (1 test)                                                               |       |
| Phoenix iteration               | exunit | `test_harness/test/stacks/phoenix/iteration_test.exs` | self (1 test)                                                               |       |
| Static iteration (vanilla)      | exunit | `test_harness/test/stacks/static/iteration_test.exs`  | self — `"vanilla change-request lands new commit with faq markers"`         |       |
| Static iteration (react/vite)   | exunit | `test_harness/test/stacks/static/iteration_test.exs`  | self — `"react change-request lands new commit with step input marker"`     |       |
| Static iteration (vue/vite)     | exunit | `test_harness/test/stacks/static/iteration_test.exs`  | self — `"vue change-request lands new commit with reset button marker"`     |       |
| Static iteration (multilingual) | exunit | `test_harness/test/stacks/static/iteration_test.exs`  | self — `"multilingual change-request lands new commit with language links"` |       |

### Section 3 — Generator Pipeline

| Surface                  | Type                | File/Path                                      | Test that exercises it                                                                         | Notes                |
| ------------------------ | ------------------- | ---------------------------------------------- | ---------------------------------------------------------------------------------------------- | -------------------- |
| generate.sh              | generator           | `templates/generator/generate.sh`              | `templates/generator/generate_test.sh` (arg validation + OUTPUT_DIR isolation)                 |                      |
| process_template.py      | generator           | `templates/generator/process_template.py`      | `templates/generator/tests/test_process_template.py` (23 unittest cases)                       |                      |
| hook_registrations.py    | generator           | `templates/generator/hook_registrations.py`    | `templates/generator/tests/test_hook_registrations.py` (38 unittest cases); `make hook-parity` |                      |
| manifest-lib.sh          | generator           | `templates/generator/manifest-lib.sh`          | `templates/generator/manifest-lib_test.sh` (14 bash cases)                                     |                      |
| config.yaml              | generator           | `templates/generator/config.yaml`              | Indirect via `make install` rendering                                                          | Schema not validated |
| test_dual_render.sh      | generator-self-test | `templates/generator/test_dual_render.sh`      | self — wired into `make test` via `templates/generator/run-tests.sh`                           |                      |

### Section 4 — Install Lifecycle

| Surface             | Type                                               | File/Path             | Test that exercises it                                                                                         | Notes                                                                                                                                 |
| ------------------- | -------------------------------------------------- | --------------------- | -------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| install.sh          | install                                            | `install.sh`          | `test_harness/install/install_claude_round_trip_test.sh` | Hermetic — `HOME` override + `ZSH_COMPLETION_DIRS` env-toggle; runner: `test_harness/install/run-tests.sh`                            |
| uninstall.sh        | install                                            | `uninstall.sh`        | same round-trip tests (called after install to verify removal)                                                 | `ZSH_COMPLETION_DIRS` env-toggle applied; interactive prompts via `printf 'N\nN\n' \|`                                                |
| resource_manager.sh | port-allocation — see `context/port-allocation.md` | `resource_manager.sh` | —                                                                                                              | Untested. NOT sourced by install.sh/uninstall.sh (prior "indirectly exercised via install" claim was false; 0 refs confirmed by grep) |
| update_ai_tools.sh  | install                                            | `update_ai_tools.sh`  | —                                                                                                              | No dedicated test; manual only                                                                                                        |
| config.sh           | install                                            | `config.sh`           | —                                                                                                              | No dedicated test; sourced everywhere                                                                                                 |
| utils.sh            | install                                            | `utils.sh`            | —                                                                                                              | `content_stable_cp` and helpers; no test                                                                                              |

### Section 5 — Scaffold Mutations

| Surface             | Type            | File/Path                                            | Test that exercises it                                                                                                          | Notes                                                                             |
| ------------------- | --------------- | ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| config_exs.sh       | mutation        | `shared/scaffold/phoenix/mutations/config_exs.sh`    | `shared/scaffold/phoenix/mutations/config_exs_test.sh` (2 cases: happy + idempotent) via `shared/scaffold/phoenix/run-tests.sh` | bash 3.2 compatible; fixture: `test_harness/mutations/fixtures/phx_new_skeleton/` |
| data_case.sh        | mutation        | `shared/scaffold/phoenix/mutations/data_case.sh`     | `shared/scaffold/phoenix/mutations/data_case_test.sh` (2 cases)                                                                 |                                                                                   |
| endpoint.sh         | mutation        | `shared/scaffold/phoenix/mutations/endpoint.sh`      | `shared/scaffold/phoenix/mutations/endpoint_test.sh` (3 cases: happy + idempotent + missing-anchor warning)                     |                                                                                   |
| formatter_exs.sh    | mutation        | `shared/scaffold/phoenix/mutations/formatter_exs.sh` | `shared/scaffold/phoenix/mutations/formatter_exs_test.sh` (2 cases)                                                             |                                                                                   |
| gitignore.sh        | mutation        | `shared/scaffold/phoenix/mutations/gitignore.sh`     | `shared/scaffold/phoenix/mutations/gitignore_test.sh` (2 cases)                                                                 |                                                                                   |
| mix_exs.sh          | mutation        | `shared/scaffold/phoenix/mutations/mix_exs.sh`       | `shared/scaffold/phoenix/mutations/mix_exs_test.sh` (7 assertions: 5 step checks + idempotency)                                 |                                                                                   |
| prod_exs.sh         | mutation        | `shared/scaffold/phoenix/mutations/prod_exs.sh`      | `shared/scaffold/phoenix/mutations/prod_exs_test.sh` (3 cases: created + has import Config + idempotent no-op)                  |                                                                                   |
| router.sh           | mutation        | `shared/scaffold/phoenix/mutations/router.sh`        | `shared/scaffold/phoenix/mutations/router_test.sh` (3 cases: happy + idempotent + find-fallback)                                | bash 3.2 bug fixed: `${@L}` → `tr '[:upper:]' '[:lower:]'`                        |
| telemetry.sh        | mutation        | `shared/scaffold/phoenix/mutations/telemetry.sh`     | `shared/scaffold/phoenix/mutations/telemetry_test.sh` (2 cases)                                                                 |                                                                                   |
| eex_render.sh       | mutation-helper | `shared/scaffold/phoenix/eex_render.sh`              | `shared/scaffold/phoenix/eex_render_test.sh` (3 cases: single var + multi var + unknown var pass-through)                       | bash 3.2 bug fixed: `declare -A` → direct key=value loop                          |
| phoenix scaffold.sh | scaffold-entry  | `shared/scaffold/phoenix/scaffold.sh`                | Indirect via `test_harness/test/stacks/phoenix/scaffold_test.exs`                                                               | Drives mutations                                                                  |
| static scaffold.sh  | scaffold-entry  | `shared/scaffold/static/scaffold.sh`                 | `shared/scaffold/static/scaffold_test.sh` (via `make harness-parity`)                                                           | Already covered                                                                   |

### Section 6 — Hook Scripts (paired tests)

For every `harnesses/claude/hooks/<name>.sh` there is a paired `<name>_test.sh` in the same dir. After Stage 1's `run-tests.sh` fix, all of them — including the two under `lib/` — execute via `make test`.

Every hook below follows the pattern `.../hooks/<name>.sh` + paired `.../hooks/<name>_test.sh`, EXCEPT
where noted:

build-worker-cwd-guard, claude-debug-bash-guard, committer-no-trailer-guard, committer-single-line-guard,
committer-subject-length, context-curator-guard, context-factcheck-edit-gate, dev-no-ci,
developer-no-self-gate, llm-pending-sweep, llm-suite-guard,
llm-test-guard, no-cat-pipe, no-git-stash, no-python-json, operator-subagent-allowlist,
orchestrator-no-ci, orchestrator-no-source-edit, orchestrator-read-discipline,
phoenix-backend-developer-guard, phoenix-frontend-developer-guard, pre-commit-guard,
reviewer-guard, session-log-writer-only, static-site-ex-guard,
subagent-read-discipline, track-subagent-edits, track-tool-failures, usage-rules-grep-guard.

Exceptions:

- **codegen-build (harness parity)** — hook-test-only, no script (test IS the surface):
  `.../hooks/codegen-build_test.sh`; invoked separately via `make harness-parity`.
- **env-var-sample-scan** — hook-lib (`harnesses/claude/hooks/lib/env-var-sample-scan.sh` +
  `..._test.sh`). Extracted for reuse by the loop's `run_env_var_step`; 20 test cases (A–T);
  documentation axis (not crash-ability) — Tests I–J: defaulted reads flagged; K–O: ambient-OS-var
  allowlist (sole exemption); P–T: `||`-fallback, `fetch_env!`, concat/interpolation non-match,
  declared-defaulted pass.

### Section 7 — Hook Shared Libraries (`hooks/lib/`)

| Surface        | Type        | File/Path                                   | Test that exercises it                           | Notes                                                                                      |
| -------------- | ----------- | ------------------------------------------- | ------------------------------------------------ | ------------------------------------------------------------------------------------------ |
| hooks-lib.sh   | hook-lib    | `harnesses/claude/hooks/lib/hooks-lib.sh`   | `harnesses/claude/hooks/lib/hooks-lib_test.sh`   | **Previously silently skipped** (`run-tests.sh` `-maxdepth 1`); reactivated by Stage 1 fix |
| gate-select.sh | hook-lib    | `harnesses/claude/hooks/lib/gate-select.sh` | `harnesses/claude/hooks/lib/gate-select_test.sh` | **Previously silently skipped**; reactivated by Stage 1 fix                                |
| run-tests.sh   | hook-runner | `harnesses/claude/hooks/run-tests.sh`       | — (runner itself)                                | No meta-test                                                                               |

### Section 8 — Shared / Root Utilities

| Surface                            | Type        | File/Path                                             | Test that exercises it              | Notes                                                    |
| ---------------------------------- | ----------- | ----------------------------------------------------- | ----------------------------------- | -------------------------------------------------------- |
| utils.sh                           | shared-lib  | `utils.sh` (repo root)                                | —                                   | `content_stable_cp` and logging helpers                  |
| config.sh                          | shared-lib  | `config.sh` (repo root)                               | —                                   | Sourced env config                                       |
| bash_completion.sh                 | shared-lib  | `bash_completion.sh` (repo root)                      | —                                   | Shell completion                                         |
| ocg                                | launcher    | `ocg` (repo root)                                     | —                                   | User CLI dispatcher                                      |
| bin/test-llm-hooks.sh              | dev-utility | `bin/test-llm-hooks.sh`                               | —                                   | Manual dev utility; not CI-wired                         |
| record-green.sh                    | shared-lib  | `test_harness/record-green.sh`                        | —                                   | Stamps `last_green.json`; invoked by `make record-green` |
| codegen_test_harness/assertions.ex | shared-lib  | `test_harness/lib/codegen_test_harness/assertions.ex` | Indirect — used by all ExUnit tests |                                                          |
| codegen_test_harness/fixtures.ex   | shared-lib  | `test_harness/lib/codegen_test_harness/fixtures.ex`   | Indirect — used by all ExUnit tests |                                                          |

### Section 9 — Make Targets (executable surfaces)

| Surface                 | Type        | File/Path                              | Test that exercises it                                                      | Notes                                                                                    |
| ----------------------- | ----------- | -------------------------------------- | --------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| make install            | make-target | `Makefile` (`install` target)          | —                                                                           | Manual; round-trip in Stage 5                                                            |
| make uninstall          | make-target | `Makefile` (`uninstall` target)        | —                                                                           | Manual; round-trip in Stage 5                                                            |
| make test               | make-target | `Makefile` (`test` target)             | self-referential                                                            | runs hook tests + mutation tests + install round-trips  |
| make test-stacks        | make-target | `Makefile` (`test-stacks` target)      | self-referential                                                            | runs ExUnit                                                                              |
| make test-all           | make-target | `Makefile` (`test-all` target)         | self-referential                                                            |                                                                                          |
| make hook-parity        | make-target | `Makefile` (`hook-parity` target)      | Round-trip diff (no unit test)                                              |                                                                                          |
| make harness-parity     | make-target | `Makefile` (`harness-parity` target)   | Invokes `codegen-build_test.sh` + `shared/scaffold/static/scaffold_test.sh` |                                                                                          |
| make harness-path-check | make-target | `Makefile (harness-path-check target)` | — (post-install grep, manual; no unit test)                                 |                                                                                          |
| make doctor             | make-target | `Makefile:226+`                        | —                                                                           | Diagnostic only                                                                          |
| make format             | make-target | `Makefile:205+`                        | —                                                                           | Formatter                                                                                |
| make record-green       | make-target | `Makefile:150`                         | —                                                                           | Baseline-stamper                                                                         |
| make test-coverage      | make-target | `Makefile:77+`                         | `make test-coverage && make test` (Stage 2 gate)                            | Chains elixir/typescript/shell/python/summary sub-targets; outputs to `coverage/<lang>/` |
| make test-generator     | make-target | `Makefile`                             | self-referential                                                            | runs Python unittest + bash `*_test.sh` for generator pipeline                           |

### Section 10 — Summary

- 17 ExUnit cases across 10 files cover the `build` mode for the `claude` harness against 2 stacks (phoenix scaffold/seed/gate/committer/iteration + static iteration × 4 variants) plus 3 mode launcher cells.
- Bash hook test files run via `make test` in `harnesses/claude/hooks/` + `harnesses/claude/hooks/lib/`. The former `phoenix-dev-gate` SubagentStop gate hook is deleted — the loop's `LoopGate` (`test_harness/lib/codegen_test_harness/loop_gate.ex`) now owns gate execution for non-interactive builds.
- 3 mode launcher cells now covered by `test_harness/test/stacks/modes/` (Stage 4): `claude-{debug,shape,refactor}`.
- After Stage 5: **9 phoenix mutations + `eex_render.sh`** have isolated unit tests (`*_test.sh` per script) wired into `make test` via `shared/scaffold/phoenix/run-tests.sh`. Two bash 3.2 bugs fixed: `router.sh` (`${@L}` → `tr`) and `eex_render.sh` (`declare -A` → direct loop).
- After Stage 5: **install.sh + uninstall.sh** covered by hermetic round-trip tests (`test_harness/install/`) with `HOME` override + `ZSH_COMPLETION_DIRS` env-toggle. Tests for `--harness=claude` (15 cases) wired into `make test` via `test_harness/install/run-tests.sh`.
- Generator pipeline now has 4 unit test files (Python unittest + bash) wired into `make test`; `test_dual_render.sh` integrated into the runner via `templates/generator/run-tests.sh`.
- Coverage entry-points wired: ExCoveralls (Elixir), c8 (enforcement+subagents), vitest+istanbul (askuserquestion+web-utils), kcov (shell), coverage.py declared (Python — Stage 3).

## Trigger Keywords

test coverage, coverage gaps, what tests exercise X, untested paths, test inventory, ExCoveralls, c8, vitest, istanbul, kcov, coverage.py

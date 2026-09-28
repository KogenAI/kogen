# Candidate hunks for shaping-stop-hook (offline slice)

Applicability: `git apply --cached --check` against a temporary index of develop
`dece3e84a25e7d3399a3c618b670caf399ea86e1` (probe P0, `probe-preflight-dece3e84/RESULT.md`), file by file, then hunk by
hunk for every file that fails as a whole. qb = `candidate-qbOzahf8-f4819c37-codex-slice.diff`, zuj =
`candidate-ZujYgSGt-555d0af3-slice.diff`. "Applies" is not "correct": each row says what to take. Only this slice's
files are listed; the evaluation files (`driver.py` beyond `pinned_smoke_config`, `integrity.py`, the transports,
`driver_rehearsal_test.py`, `jev_layer.ex`, the live owners, `shaping_evaluation_test.exs`) are
`shaping-evaluation-live`'s.

## Take (applies at dece3e84)

| File | Source | Applies | Use |
|---|---|---|---|
| lib/kogen/shaping_audit/stop_hook.ex | qb | yes (new file) | Take, then make the thirteen changes under "Adapt to the landed code" below. |
| priv/kogen/shaping_audit/stop_hook.sh | qb | yes (new file) | Take (mode 0755). Add `cd "$root"` before `mix` (qb runs it from the caller's cwd), and hash paths relative to the package directory (qb's `find "$pkg_dir"` hashes absolute paths, so a moved checkout never hits the cache). Its role check `[ "${KOGEN_ROLE:-}" != "shaper" ]` already treats unset as non-shaper. |
| lib/kogen/harness.ex | qb hunk 2 of 3 (`role_context` + `tag_current_role`, `@@ -162`) | yes | Take. Hunk 1 (`exports`) and the `open_auditor`/`launch_auditor` part of hunk 3 already landed (slice 2, `harness.ex:352-361`). |
| lib/kogen/harness.ex `shaping_stop_hook/0` | qb hunk 3 | no (its context is slice 2's landed functions) | Insert by hand after `launch_auditor/4` (`harness.ex:359-361`), before `exec_shaper/4` (`:363-365`). |
| lib/kogen/harness/codex.ex | qb hunk 2 of 2 (`shaper_args`, `@@ -216`) | yes | Take (`shaper_hook_flag/0` and `--search`; `shaper_args/3` is at `codex.ex:265-267`). Hunk 1 already landed. |
| lib/kogen/codex/environment.ex | qb hunks 2-4 | yes | Take. Hunk 1 already landed (`environment.ex:188-189`). |
| lib/mix/tasks/kogen.shape.ex | zuj | yes | Take (the four `KOGEN_SHAPING_*` variables and `toolchain_path/0`; `Kogen.Intent.mint_uuid7/0` is at `intent.ex:667`). |
| priv/kogen/prompts/shaping.md, shaping-continuation.md, shaping-fresh.md | zuj | yes | Take, then insert the exact sentences scenario `shaping-flow-prompts-and-codex-launch` lists (zuj's text lacks six of them) and check every substring P1 asserts. |
| test/kogen/codex_environment_test.exs | qb | yes | Take its one new test (P3). |
| test/support/shaping_audit/fake_mix, hook/{root,helper}-rollout.jsonl | qb | yes | Take. |
| test/support/shaping_evaluation/driver_smoke_rehearsal_test.py | qb hunks 1 and 4 of 5 | yes | Take the `difflib` import (hunk 1) and the pin-test body (hunk 4), then tighten it to K1's exact diff (qb's `len(edits) <= 2` is looser). **Never hunks 2, 3 or 5**: they rewrite the fake's `questions.md` and the catalogued wrong control `test_smoke_wrong_control_missing_scripted_answer_fires_fail_fast`; both stay byte-identical here. By hand (not in qb): `setUp`'s `codex-fake` route gains the `auditor:` line and `helpers:` block, and its `.gitignore` gains `.kogen/runtime/` (scenario `smoke-fixture-without-auditor`); K3's `hook_files` keyword. |

## Not taken

| File | Why |
|---|---|
| test/support/shaping_audit/fast_auditor.ex | Its only caller is slice 5's `live-shape-to-build` test (`FastAuditor.patch!`); `mix.exs` compiles no `test/support` path. Plumbing without a caller (direction 9). Slice 5 adds it. |
| test/kogen/shaping_audit_hook_test.exs (qb harness) | Injects `layers:` fakes (`FakeMaterialization`, `FakeDeterministic*`, `FakeAuditor*`, `FakeJevPassthrough`) that the landed `audit/2` does not accept, and its `env/2` never clears `KOGEN_HARNESS_HOME`. Write H1-H28 on the landed fakes. Its `minimal_path!/1` and fake-mix log reading are usable as reference; its "live-shape-to-build probe" describe is slice 5's. |
| lib/kogen/shaping_audit/report.ex | The landed file already has `runtime_dir/2`, `write/3` (schema 2) and `latest_revision/2`. |

## Extend the landed files by hand

| File | Use |
|---|---|
| lib/kogen/shaping_audit.ex | In `main/2`: `stop_hook: :boolean` in `parse_args/1`'s strict list; `["--stop-hook"]` alone dispatches to `StopHook.run/3` and returns 0 **before** `run_command/8`'s role and lock refusals; `--stop-hook` with any other flag or a slug is a usage error (2); the usage line gains ` \| mix kogen.audit --stop-hook`; `main/2` gains `:stdin`. In `run_command/8`, after the role and lock refusals, `KOGEN_ROLE=shaper` with a blank `KOGEN_SHAPING_HOOK_OUTPUT` prints the inside-Shaping status for every form. Extract `error_text/1` (public, `@doc false`) from `report_error/2` (`:151-169`): the same four texts; `report_error/2` prints `error_text(reason)` and returns 2 as before. qb's `main/2` shape (qb diff lines 47-133) is the reference; keep the landed `normalize_env/1`. |
| lib/mix/tasks/kogen.audit.ex | Add the `--stop-hook` paragraph to the moduledoc only. `run/1` stays byte-identical. |
| test/kogen/shaping_audit_task_test.exs | Add H26. Change the landed test "an approved-only package and the Shaper role run normally" (`:242-254`) as scenario `stop-hook-decides-every-stop` states. |
| README.md | Edit slice 2's "### Shaping audit" section: replace `:1018-1019` and `:1030-1031`, add the Stop-hook paragraph. `:990-992` stays byte-unchanged. |

## Port by hand (the source hunk conflicts at HEAD)

| File | Source | Use |
|---|---|---|
| test/kogen/harness_role_test.exs | zuj hunk 1 | New test P2, extended to `auditor_args/2` (`codex.ex:216`). The landed test "no harness exposes an auditor launch" (`:766`) stays. |
| test/kogen/shape_task_test.exs | zuj hunk 1 | Into the existing test row t003 (P1). Hunk 2 (the Claude tools) is slice 5's. |
| test/support/shaping_evaluation/driver.py `pinned_smoke_config` | qb's version (qb driver.py `:1573-1586`) removes the auditor line only | Write it as INTENT.md "Smoke fixture" states (auditor removed, `worker`/`expert` pinned). Nothing else in `driver.py` changes here. |

## Adapt to the landed code (qb `stop_hook.ex`)

1. Call the landed `Kogen.ShapingAudit.audit(root, %{slug: slug, route: env["KOGEN_SHAPING_ROUTE"], auditor: true,
   env: env, opts: opts})`. Drop qb's `:launch?` opt.
2. The landed `:clock` returns a `DateTime` (qb: an integer, default `System.system_time(:millisecond)`, in qb's `run/3`). Convert with `DateTime.to_unix(t, :millisecond)`; read it exactly twice per audited stop, before and after
   the audit.
3. `launch_ms` uses the second clock read. qb's `launch_ms/1` reads `System.system_time/1`
   itself; no function in the hook may.
4. Decode `KOGEN_SHAPING_LAUNCH_ID` only when it is a UUIDv7 (the 13th hex digit is `7`); otherwise `launch_ms` is
   null. qb's `uuidv7_ms/1` decoded any hex prefix.
5. `block_reason/3` becomes public (`@doc false`) with the signature `(open_blocking_findings, advisory_count,
   report_path)` and does its own truncation to 16 384 bytes: drop finding lines from the end, add `- … <k> more
   blocking findings in the report`, keep `advisory: <n>` and `report: <path>` last, never split a UTF-8 character.
   qb's `truncated_reason/3` cut with `binary_part/3` and lost the `report:` line.
6. Use the landed `Report.runtime_dir/2` instead of qb's private copy, and keep `hook-state.json`'s
   `last_revision` key (the landed `Report.latest_revision/2` reads it).
7. `chain_ms` is computed from the `chain_start` **stored before this stop** (for a chain-starting block: 0). qb
   computes it from `decide_outcome/5`'s result, which is already `nil` at an allowed stop, so it records 0 where
   H16 expects 2 400 000.
8. Keep qb's per-kind chain state (INTENT.md "The chain" table): `stalled` and `auditor-bound` keep
   `chain_blocks`, `ready`/`asking`/`environment`/`block-limit` reset it, every allowed stop clears `chain_start`,
   `error` leaves the state unchanged. The Draft's old sentence "the chain resets at every allowed stop" is now
   stated for the clock only (H4 keeps `chain_blocks` 1 after a stall).
9. Block-limit text: `"not ready after 8 blocks in this chain; allowing the stop to avoid a trap.\n" <>
   block_reason(...)`. qb wrote "allowing to avoid a trap. " and the untruncated reason.
10. Presented summary: lines joined by `"\n"` (qb: sections joined by `"\n\n"`); minutes as
    `:erlang.float_to_binary(ms / 60_000, decimals: 1)` followed by ` min` and `n/a` for null (qb: `Float.round/2`,
    an `m` suffix and `?`); the lines `Assumed: none`, `Left undecided: none` and `Not audited by the auditor:
    none` when empty (qb omitted the section); every entry printed as `- <text>` from the landed report's
    `questions.sections` (qb appended "(Recommended: …)" to a text that already carries its Recommendation); no
    "Disputed" block.
11. `{:error, reason}`: `"shaping audit error: " <> Kogen.ShapingAudit.error_text(reason) <> "; run mix kogen.audit
    <slug>"`. qb wrote `"shaping audit refused: #{inspect(reason)}"` (qb's `run/3`, `{:error, reason}` branch).
12. `hook.jsonl`'s `chain_blocks` is the value after the stop, and its `elapsed` is the map written into
    `report.json` (qb already does both; keep them).
13. An `error` decision is never cached: after an `error` stop `hook-state.json`'s `skip_key` and `decision` are
    null, as after a block, so the next stop re-audits (H13). qb's `log_and_return/4` clears them only for a
    block, so it cached the error under the environment's skip key and `stop_hook.sh` would replay it on an
    unchanged package.

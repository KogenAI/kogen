# P4/P5 probe report

## P4 — provider markers (verified against real retained transcripts)

**Claude rate-limit (BE-N9cRQpgL7WJ8ieVHEVFzu, session e9508db9-566c-4329-b3e5-e1ff5e566b60)**
- Rich transcript: `~/Library/Application Support/Kogen/claude/accounts/shared/projects/-Users-almirsarajcic-Areas-Kogen-kogen/e9508db9-566c-4329-b3e5-e1ff5e566b60.jsonl`, line 1044/1046 (i.e. the session's second-to-last event, well inside the tail):
  `"error":"rate_limit","isApiErrorMessage":true,"apiErrorStatus":429` with
  `"quotaLimits":{"status":"rejected","rateLimitType":"five_hour",...}` and
  `content:[{"type":"text","text":"You've hit your session limit · resets 9:30pm (Africa/Nairobi)"}]`.
- The raw stream-json embedded in `record.json` (`attempts[0].developer_invocation.diagnostics`, 4,769,924 chars) carries the same text at offset 4,759,915 of 4,769,924 (within ~10 KB of EOF) and the terminal `result` object — inside the **last 4000 chars** of the stream — is:
  `"terminal_reason":"api_error", ... "is_error":true,"num_turns":225,"subtype":"success","api_error_status":429,"result":"You've hit your session limit · resets 9:30pm (Africa/Nairobi)","type":"result", ...`.
  `developer_invocation.outcome == "provider_failure"`.
- Confirms: the limit marker is at the very end of the stream, structured (`api_error_status:429`, `is_error:true`, `terminal_reason:"api_error"`) and duplicated in text (`result` field). NOTE: `subtype` is misleadingly `"success"` even though `is_error:true` — do not use `subtype` as a marker.

**Codex capacity (hJeqtBSgm52RC3xO6fMza8gq, rollout 01a0d2a9-5e20-7bb1-ad2e-64393bc25d33)**
- `record.json` attempt's `developer_invocation.diagnostics` (50,552 chars): last ~150 chars are
  `{"type":"error","message":"Selected model is at capacity. Please try a different model."}` followed by
  `{"type":"turn.failed","error":{"message":"Selected model is at capacity. Please try a different model."}}`.
  `developer_invocation.outcome == "provider_failure"`.
- Raw Codex rollout JSONL: `~/Library/Application Support/Kogen/codex/accounts/shared/sessions/2026/09/24/rollout-2026-09-24T12-05-10-01a0d2a9-5e20-7bb1-ad2e-64393bc25d33.jsonl`, **last line** (56/56):
  `{"type":"task_complete", ..., "error":{"message":"Selected model is at capacity. Please try a different model.","codex_error_info":"server_overloaded"}, ...}`.
- Two related but distinct schemas carry the same marker: the exec/stream-json form (`type:"error"`/`type:"turn.failed"`, freeform message only) and the rollout form (`type:"task_complete"`, structured `error.codex_error_info:"server_overloaded"`). The structured field is strictly more reliable than the freeform message.

**5xx examples** — none found in this environment's retained data. Grepped all of `~/Library/Application Support/Kogen/claude/accounts/shared/projects` and `.../codex/accounts/shared/sessions` for `overloaded_error`, `"error":{"type":"...` Anthropic error shapes, and Codex `codex_error_info` values: the only Codex values ever observed are `server_overloaded`, `usage_limit_exceeded`, `other`. No genuine `529`/`500`/`overloaded_error` sample exists to verify against; the only real provider-denial samples in this environment are the 429 (Claude) and `server_overloaded` (Codex) cases above. This is an evidence gap, not a negative result — a marker set must still include 5xx handling but it is unverified here.

**Negative control (btwokrNxL50md1z5Fb-GGYOO, `make live-native`, all 3 cycles)**
- Full receipt outputs (see P5 below) contain `{:provider_exit, 124, "..."}` for every cycle — a *local* turn-launch timeout (offline.py's own `124` convention for a reaped process, see `scripts/check/offline.py:60`), not a provider error.
- Checked for every P4 marker (`session limit`, `rate_limit`, `capacity`, `overloaded`, `server_overloaded`, `api_error_status`, `codex_error_info`, `"is_error":true`, literal `429`, `usage_limit_exceeded`, and a `5\d\d` regex): all false, except a `5\d\d` regex false positive matching a timestamp/log-line substring (`14:03:26`, file-size `583`), not a real status code. Confirms a marker-only classifier correctly leaves this a paid/non-provider failure — matches the task's expectation.

**Proposed marker set (structured-field-first):**
1. `developer_invocation.outcome == "provider_failure"` (necessary but not sufficient — gates which builds to even look at).
2. Claude: `apiErrorStatus` (or embedded stream's `api_error_status`) is present and in `{429} ∪ {500..599}`, OR `error == "rate_limit"`, OR `terminal_reason == "api_error"` combined with `is_error:true`.
3. Codex: rollout/event `error.codex_error_info` in `{"server_overloaded","usage_limit_exceeded"}` (structured field — preferred), else text `error.message` matching `/at capacity|overloaded|rate limit/i` (fallback for the exec/stream-json form, which lacks `codex_error_info`).
4. Text fallback only when no structured field exists: `/you'?ve hit your (session|usage) limit|selected model is at capacity|overloaded_error|(^|[^0-9])5\d\d([^0-9]|$)/i` restricted to a line also containing `error`/`turn.failed`/`result` — do not bare-grep the whole blob (the `5\d\d` regex alone produces false positives on timestamps/byte counts, as observed above).
- Ambiguity: `subtype` in Claude's `result` event is not reliable (`"success"` even on `is_error:true`); no confirmed 5xx sample exists to validate the `5\d\d` branch; the exec/stream-json Codex form never carries `codex_error_info`, only the rollout form does, so which one a given failure path retains matters.

## P5 — signature prototype

Prototype: `sig_proto.py` (in this directory). Computes:
- **frame** = sha256(`stage=<failing offline.py stage>` + `test=<first "N) test ... (Module) file:line">` + `assertion=<first informative reason line after that header>`).
  Stage detection: offline.py (`scripts/check/offline.py`) prints a stage's captured stdout **before** its own `Stage elapsed (<cmd>): Xs` line (`offline.py:74-77`), so the failing stage is the first `Stage elapsed` line **after** the first ExUnit failure marker (or, for non-ExUnit failures such as compile/format, the first `+ <command>` with no matching later elapsed line).
  Assertion detection needed care: isolated-process tests (`Kogen.IsolatedCase`) wrap the real failure in an `isolated test ... failed ({:exit_status, 1})` banner and a nested re-run of the same `N) test ...` block; the code skips that wrapper to reach the actual reason line, which is often freeform text (e.g. `pty success: terminal probe failed: [Errno 9] Bad file descriptor`), not one of ExUnit's own `code:`/`left:`/`right:`/`Assertion` markers.
- **fallback** = sha256(last 20 nonblank output lines after normalization: strip ANSI; replace ExUnit `--seed N`/`Randomized with seed N`; `Finished in X seconds`; bare `\d+(\.\d+)?s` durations; ISO timestamps; `/private/tmp/...`, `/var/folders/...`, and Codex `.../compatibility/compatibility-<epoch>-<port>/...` fixture paths; hex digests ≥12 chars; and the per-run `KOGEN_ISOLATED_COMPLETION\t...` token line).

### Results table (build / cycle / target / today's `digest` from record.json / frame / fallback)

| build | cycle | target | today digest (first 12) | frame (first 16) | fallback (first 16) | first failing test |
|---|---|---|---|---|---|---|
| ZJDgU9wo | 1 | check | e3c761c920c2 | 322d5e3b909a9c62 | 859eb7860dc3b63c | ScenarioLifecycleTest:200 |
| ZJDgU9wo | 2 | check | e3c761c920c2 | 79b93b6fea313c8f | 60c2cb853a249a93 | CodexPublicTasksTest:52 |
| ZJDgU9wo | 3 | check | e3c761c920c2 | b9fd34a444590e1a | 9b09f73dc105cdf3 | CommitProvenanceTest:24 |
| _8Qpvuip | 1 | check | e3c761c920c2 | b9fd34a444590e1a | f98605000491e854 | CommitProvenanceTest:24 |
| _8Qpvuip | 2 | check | e3c761c920c2 | d05c898584051d39 | 05afbdbeb1da6ec3 | LifecycleTest:21 |
| _8Qpvuip | 3 | check | e3c761c920c2 | d05c898584051d39 | a90a5f68e91d34e9 | LifecycleTest:21 (same as c2) |
| a2sPFUvF | 1 | check | e3c761c920c2 | 9047b37fbf4380a9 | d1d452a3f47c3f55 | TestReliabilityCatalogTest:15 |
| a2sPFUvF | 2 | check | e3c761c920c2 | bf3b69d7e55f4c7b | ea81fe0787deb94a | IntentTest:102 |
| a2sPFUvF | 3 | check | e3c761c920c2 | f3bc9c82bd215f25 | b7595936a4591fdb | ClaudeCode.ManagementTest:82 |
| hAOGGjSC | 1 | check | (n/a, not "digest" record) | 037c5c81dec715f9 | d41a483075be8307 | HarnessRoleTest:6 — "pty ... Errno 9 Bad file descriptor" |
| hAOGGjSC | 2 | check | (n/a) | d9fe08739892040d | df43c665b8ea9268 | OfflineStageResultsTest:70 — "timed out after 120000ms" |
| hAOGGjSC | 3 | cold-offline | (n/a) | 7d9ddbc806e86a88 | 8a53951bfc434876 | ColdOfflineTest:11 |
| btwokrNx | 1 | live-native | (record uses `error_head`, not `digest`, for this target) | bdc8aad09abe59d9 | b376c7f1c9bc944b* | CompatibilityTest:163 (`:launch_reviewer`, `provider_exit 124`) |
| btwokrNx | 2 | live-native | " | 8db995477054afe5 | 3e38f7a6779ebb6d* | CompatibilityTest:163 (`:launch_developer`, `provider_exit 124`) |
| btwokrNx | 3 | live-native | " | 43949dd2d61411f6 | b376c7f1c9bc944b* | CompatibilityTest:163 (`:launch_reviewer`, `provider_exit 124`) |
| Bg1qobsC | 1 | check | (compile failure, no ExUnit test) | 00844f0748bdbab4 | b5076617dbfeb4df | `mix compile --warnings-as-errors --force` |
| Bg1qobsC | 2 | check | (compile failure) | 00844f0748bdbab4 | 20ab443fefd504a1 | same compile stage as c1 |

*after extending the tmp/fixture-path and per-run-token normalization rules described above.

### Claim checks
- **ZJDgU9wo / _8Qpvuip / a2sPFUvF distinct where causes differ**: confirmed. All 3 builds share the exact same `record.json` `digest` (`e3c761c920c240184ab1b2dee1dd78a8b3131073064f8b3bfcb189c96e116e00`) across all 9 (build×cycle) receipts even though every one is a *different* failing ExUnit test. Both frame and fallback correctly split these into 9 distinct signatures (except the two legitimate repeats noted below), which demonstrates today's `digest` (computed elsewhere from a truncated `error_head` of boilerplate offline-gate preamble text — see `record.json`'s `error_head` strings, which are byte-identical "…/usr/bin/time -p python3 scripts/check/offline.py Resolved Git executable: …" prefixes) is not discriminating; it collapses unrelated root causes.
- Two genuine repeats found (not collisions, real re-occurrences): `_8Qpvuip` cycle 2 and 3 both fail `LifecycleTest:21` (frame and fallback both correctly show these as the *same* signature — expected, since rework didn't fix it), and `ZJDgU9wo` cycle 3 / `_8Qpvuip` cycle 1 both fail `CommitProvenanceTest:24` (again same signature, correct — this looks like a shared flaky/real regression that carried across builds).
- **hAOGGjSC c1 ≠ c2**: confirmed via both frame and fallback. c1's first failure is `HarnessRoleTest` with a PTY `[Errno 9] Bad file descriptor` reason line; c2's is `OfflineStageResultsTest` with an ExUnit 120000 ms timeout. This matches the task's description ("c1 PTY EBADF, c2 120s timeout") once the assertion-line extractor is taught to skip the `Kogen.IsolatedCase` wrapper banner (see below).
- **btwokrNx c1 = c2 = c3 via fallback**: partially confirmed. With the base 20-line/ANSI/seed/duration/timestamp/hex normalization only, all three fallback hashes differed, because (a) the Codex compatibility fixture directory name (`compatibility-<epoch>-<port>`) lives under `~/Library/Application Support/...`, not `/private/tmp` or `/var/folders`, so the original tmp-path rule missed it, and (b) each isolated rerun emits a unique per-run `KOGEN_ISOLATED_COMPLETION\t<opaque-token>\t...` line. After adding rules for both, c1 and c3 collapse to an identical fallback signature; c2 remains distinct because c2's failure genuinely occurred in a different sub-phase (`:launch_developer` vs `:launch_reviewer` inside `{:compatibility_turn, ...}`) — a real, not spurious, difference in *which* provider turn hung. I judged this is legitimate signal, not noise to normalize away, and left it as a documented deviation from the task's "c1=c2=c3" expectation rather than force a false collapse.

### Tuning / normalization rules (final)
- Strip ANSI escapes.
- Replace `--seed N` / `Randomized with seed N`.
- Replace `Finished in X seconds` and bare `\d+(\.\d+)?s` duration tokens.
- Replace ISO-8601 timestamps.
- Replace `/private/tmp/...`, `/var/folders/...`, **and** any path containing a `compatibility-<digits>-<digits>` segment (Codex compatibility-fixture temp dirs live under `~/Library/Application Support/...`, outside the two canonical tmp roots — this needed to be added).
- Replace hex digests ≥12 chars.
- Replace the whole `KOGEN_ISOLATED_COMPLETION\t...` line (carries a unique per-run opaque token that is not strictly hex, so the hex-digest rule alone misses it).
- (Not applied, flagged as a judgment call) normalizing `:launch_developer`/`:launch_reviewer` inside `{:compatibility_turn, ...}` would force-collapse btwokrNx c2 into c1/c3, but that erases real information about which turn hung.
- No collisions found between causally-different failures at N=20 lines for the fallback signature in this sample; the only same-signature pairs are cases confirmed to be the same real failing test recurring.

### Excerpt-size measurement
Measured, per failing receipt, how many non-blank lines from the **end** of the (normalized) output the first `"N) test ... (Module)\n file:line"` header sits at. Result: it ranges from 25 (btwokrNx, single-failure isolated receipts) up to **232 of 262** total lines (a2sPFUvF cycle 2, `IntentTest`) — i.e. the assertion can sit almost at the very top of a long receipt. A last-**20**-line fallback window as specified **does not reliably include the failing assertion** whenever a receipt logs more than ~1 ExUnit failure, a slow isolated rerun banner, or (for `check`) the full credo/compile preamble ahead of `mix test`. The frame signature (which parses the whole receipt with `re.search`, not a tail window) does not have this problem. Recommendation: either enlarge the fallback tail window substantially (unbounded, or a stage-aware slice starting right after the relevant `+ mix test ...`/`Stage elapsed` markers) or use the frame signature as primary and treat fallback strictly as a secondary "did the whole receipt change" hash, not an assertion-bearing excerpt.

## Files
- `sig_proto.py` — the prototype (frame + fallback signature functions, stage/test/assertion extraction, CLI dump used to build the table above).
- `rows.jsonl` — raw per-receipt output of the last run of `sig_proto.py`.

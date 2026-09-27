**Verdict: not ready**

Most of the Draft holds up against b775974b. The citations match, `affected_paths` is a subset of `may_change_guarded_paths`, nothing needs slices 3–4, and every layer runs offline. But three of the nine landed tests it edits (B7, C2, D7) fail as specified, and several specified tests can't be written as described. A Codex Developer following it literally would not pass on the first try.

## Blocking findings

1. **Dispositions are applied too late.** `evidence/CANDIDATE.md:59-63` orders the audit as auditor, then Jev, then `Finding.apply_dispositions/2`.
   - qb's auditor gate checks the raw deterministic findings (candidate diff `:1331`). A disputable finding that has a "not a defect" disposition therefore still counts as open. The auditor is `skipped`, readiness becomes `not_ready`, and two landed tests fail:
     - B7 expects exit 0 and `ready` (`test/kogen/shaping_audit_checks_test.exs:417,421`);
     - C2 expects `ready` (`:448`).
   - qb's fix-check only runs when a finding already carries a `fixed` disposition (diff `:2357`). That never happens before Jev runs, so R10's `still_open true` (`scenarios.yaml:633`) and J6 (`:126-128`) can't be produced.
   - J6 has a second problem. The J runs don't pass `--auditor` (`:41`), but qb fix-checks only auditor findings (diff `:2049,:2061`). The "fixed pair" in `jev-clauses` has no defined finding source.
   - Fix: apply dispositions to the deterministic findings before the auditor gate, and to the auditor findings before routing and the fix-check. Say which findings get a fix-check and what J6's pair is.

2. **D7 can't exit 0 in the compiled fixture** (`scenarios.yaml:566-570`).
   - `auditor.ex` reads `priv/kogen/prompts/auditor.md` (diff `:1304`) and `jev_layer.ex` reads `priv/kogen/shaping_audit/*.json` (diff `:2071-2073`), both relative to the working directory.
   - `mix_task!` runs with `cd: fixture` (`test/support/compiled_fixture.exs:103`), and the fixture's `@fixture_files` (`:4-29`) contain none of these four files.
   - The obvious fix, editing `compiled_fixture.exs`, is outside `may_change_guarded_paths`. The Draft needs to name the fix, for example `Fixture.repo!(compiled: true)` copying the four files.

3. **S5's facts can't be observed as specified.**
   - **Claude half:** `ClaudeCode.open` runs `<KOGEN_HARNESS> auth status` through `System.cmd` before any launch (`lib/kogen/claude_code.ex:414,434`).
     - qb's `fake_auditor` has no `auth` branch and does `cat` on a stdin that stays open (diff `:8267`), so it hangs.
     - It also always prints the session id `fake-auditor-session` (diff `:8314`), which the adapter rejects as a mismatch (`lib/kogen/harness/claude.ex:407-411`).
   - **Codex half:** the managed trace records only args, scope, `HOME`, `OPENAI_API_KEY` and the executable (`test/support/managed_codex_fixture.py:17-19`). It has no `KOGEN_PROJECT_ROOT`, working directory, environment or stdin, and that file is unguarded.
   - `INTENT.md:380-385` and `scenarios.yaml:463-466` need to add the fake's `auth` handling and session-id echo, and say where the Codex environment and working-directory facts come from.

4. **The privacy allowlist contradicts the byte-pinned tables.** `INTENT.md:217-229` says requests carry "exactly" a list that omits the scenario's `given` and `when`.
   - `question-set-v1.json:235-239` (`clause-provider-only`) sends `given` and `when`.
   - `fix-check-v1.json:5-8` sends them too.
   - The Developer must either drop calibrated state or break "exactly". Either choice gives the Reviewer a finding.

5. **G7 contradicts the calibrated gate request.** `scenarios.yaml:260-261` says "every gate request asks only the gate question".
   - Calibration sends `gate` and `settled_by` in one request (`calibrate_gate_v3.py:83`).
   - qb does the same (diff `:2437-2441`).
   - Fix: say the gate request holds exactly `gate` and `settled_by`.

6. **Several `then` clauses have no listed test.**
   - Jev: readiness is `ready` with only advisory Jev findings (`scenarios.yaml:58-59`). No J run passes `--auditor`, so no J test can ever reach `ready`.
   - Jev: stored answers and digests, never response bodies (`:75`).
   - Gate: the stored route keeps distributions, model and wording version (`:216`), and the package's `## Settled` entries are appended at run time (`:199`).
   - Auditor runs: a missing setting gives `unavailable` naming the route, with no launch (`:538`), and the materialization is removed after every run (`:550`).
   - Auditor setting: the production parser accepts the schema's example object (`:408`).

## Notes

- **Citations:** every citation I checked matches, including the `shaping_audit.ex`, `report.ex`, `finding.ex`, `questions.ex`, `intent.ex`, `build.ex:2121`, `jev.ex`, `codex.ex`, `claude_code.ex`, `codex/state.ex`, README and config lines, plus the lifecycle and test lines the Draft names. I couldn't compute the three SHA-256 literals because I had no shell.
- **The nine tests:** A2, B3, B7, C2, C5, D1, D2, D6 and D7 are confirmed and all guarded. Six have correct new expectations. B7, C2 and D7 fail as described above.
- **D6:** should say it merges `KOGEN_ROLE=shaper` into `audit_env!` (`test/kogen/shaping_audit_task_test.exs:241`). Otherwise the Shaper-role check is silently dropped.
- **Switch to `Kogen.IsolatedCase`:** sound. Tests generated with `for` and `unquote` already work under it (`controller_verification_test` and others), and children do inherit the Build session's environment. The env-clearing rules cover every call type in the Draft.
- **S6:** `assert_raise` with a literal string needs an exact match, but the real messages are longer (`codex.ex:382`, `claude_code.ex:478`). Use a regex.
- **qb code that must change, and the Draft says so:**
  - R6 needs `bound_reached: true` on the first run, where qb returns `false` (diff `:1469`).
  - J6 needs `partly` to keep a finding open, where qb closes it (diff `:2373`).
  - `fake_auditor` still needs `git rev-parse HEAD`, a file list excluding `.git/`, and `FAKE_AUDITOR_FAIL`. `CANDIDATE.md:48` says only "Take".
  - `fake_jev_audit` needs per-entry gate knowledge for its new default.
- **First-try traps:**
  - R2: the fake logs `pwd -P` (`/private/var/…`), while `System.tmp_dir!()` is `/var/…`, so a plain prefix comparison fails.
  - J1: the test forbids the string `.kogen/intents` in its own source file.
  - S2: it names route `primary`, but `intent_test`'s `@valid_config` uses `codex` (`:77-80`).
- **Environment:** the claude.ai Stripe connector needs authorizing in your claude.ai connector settings before it can be used. It wasn't needed for this review.

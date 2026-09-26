# Probes run during Shaping (2026-09-26, on clones of main 98ebcfb2; re-baseline probes on 7ed41f66)

Each probe ran in a disposable clone or mini-project under the Shaping scratchpad,
never in the checkout.

| Assumption | Probe | Result | Folded into |
|---|---|---|---|
| Claude honours the per-launch verdict schema (enum, min/maxItems, path pattern) on launch and on `--resume` | probe-claude-verdict-schema | PASS; the adversarial control was resisted; the re-ask kept the session and the judgement. Finding: prose in `receipt` | per-launch-verdict-schema, reviewer-reask-once |
| Codex honours the same on `exec` and `exec resume` | probe-codex-verdict-schema | FAIL, then PASS. Lookaround patterns are rejected (400 `invalid_json_schema`); a lookaround-free pattern passes on launch and resume | per-launch-verdict-schema |
| Main tolerates `offline_retries` and `prepare:`; the preload launch works; a test-compile-first command exists | probe-loaders | PASS. `mix test --exclude live --warnings-as-errors --exclude test` takes about 1 s; 46 modules preload; unknown keys are ignored | test-warnings-fail-first, risks self-hosting-* and lazy-controller-modules |
| Provider markers are recognisable; signatures separate the mined failures | probe-signals | PASS with corrections: structured fields first; `subtype` is untrustworthy; no real 5xx sample; btwokrNx c2 differs; a tail excerpt misses assertions | environment-and-provider-classes, signatures-identify-failures, handoff-lists-all-evidence |
| The three prepare setups run standalone without a provider; build.lock; canonical path; missing answer; driver no-cancel | probe-prepare | PASS with findings: the driver copies build.lock; the scope hash is not canonical; the failure manifest needs its own validation mode; one rehearsal test relies on cancel | prepare-rehearsed-in-check, shaping-suite-finishes-cases. The canonical scope key and live-native's prepare moved out (Shaper's review, option B); not fixed by isolated-candidate-workspace, so still unowned |
| A recompile during the Build reaches the running controller; preloading pins it | probe-preload | PASS. Without preload the VM sees the Candidate's recompiled Report; with preload it doesn't. The 6-line task patch loads 46 modules before `Kogen.Build.run` in 0.34 s | Superseded: isolation (7ed41f66) closes it for Builds; see probe-isolation |
| After isolation (7ed41f66), Candidate compiles can't reach the controller's _build; the schema probes still pass through the new launch path | probe-isolation, probe-{claude,codex}-verdict-schema/run-7ed41f66 | PASS: 2 isolation tests pass; both harnesses pass launch and resume | risk lazy-controller-modules, the launch, reviewer-reask-once |
| A single tiny real smoke case through the edited driver finishes in minutes; driver turn-end code works on real retained rollouts | probe-shaping-smoke | Run 1 hung (transport starts the default claude route: a main bug since 6cdb2912). Run 2 passed in 410 s at medium effort. **Run 3 passed in 156 s** (low effort, minimal Draft). Replay: the real `task_complete_count` over 59-run-era rollouts | shaping-smoke-target, driver-turn-end-replay, risk overlap-shaping-preflight-audit |
| `.gitignore` can be an ordinary guarded file without letting a Candidate hide changes | probe-gitignore | PASS: hidden files are still flagged by the frozen ignored manifest; declared edits pass; undeclared edits are refused | declared-gitignore-edit |
| Rules that fail `check` or a Build on simple edits can be relaxed without losing their protection | probe-rigidity | PASS with findings: the hash catalog misses 7 stale declarations; config suffix, prose, hook bytes, Make equality and unused routes fail harmless edits; one helper locator corrected by the root | test-catalog-binds-declarations, config-checked-by-reader, docs-and-prompts-checked-by-meaning, hooks-checked-by-behavior, helper-make-targets-allowed |

Environment finding: during Shaping, an outside Codex run created `plugins/` in the
shared Kogen Codex scope at 08:47, and Kogen's readiness check refused the scope.
The Shaper removed it.

Remaining limitations:
- Single samples.
- The 5xx fixture is synthetic, because there is no real sample locally.
- Resisting an adversarial instruction is strong but not conclusive evidence of
  constrained decoding.
- The paid targets `live-shaping-quality` and `live-reviewer-rework` still run
  inside the Build, as the contract requires.

# Open Review findings after Build ECWEF8VfCUl1pM-sXryln-2K (last attempt, verdict rework)

1. The Jev layer can read KOGEN_JEV_SECURITY or KOGEN_JEV_TRANSPORT from the process environment when main/2 receives an explicit env map without those keys, violating the privacy/environment contract that Jev executables come only from main/2's env. (scenarios: jev-contract-questions)
   - lib/kogen/shaping_audit/jev_layer.ex: jev_opts/1 drops absent values from the explicit main/2 env.
   - lib/kogen/jev.ex: Kogen.Jev.security/2 and transport/1 then fall back to System.get_env/1, allowing executables outside main/2's env.
2. Question-gate findings use '## Ask the Shaper entry ...' wording and em-dash punctuation instead of the approved exact messages ('question <n> is already settled...' and 'question <n> is technical: ...'). (scenarios: question-gate-routes-questions)
   - lib/kogen/shaping_audit/jev_layer.ex: ask_gate_finding/2 emits the cited and technical gate messages.
   - .kogen/intents/approved/shaping-audit-jev-and-auditor/scenarios.yaml: G3/G4 require exact messages beginning 'question <n> ...'.
3. The two questions.md structural findings remain disputable because their rules are absent from Finding's mechanical set; recommendation-without-evidence and assumption-without-reason therefore fail the approved blocking contract. (scenarios: questions-md-states)
   - lib/kogen/shaping_audit/questions.ex: Questions.findings/2 constructs recommendation-without-evidence and assumption-without-reason with Finding.new defaults.
   - lib/kogen/shaping_audit/finding.ex: Finding.@mechanical excludes both required mechanical rules.
   - .kogen/intents/approved/shaping-audit-jev-and-auditor/scenarios.yaml: F3 and F6 explicitly require disputable false.
4. Auditor launches inherit KOGEN_HARNESS_HOME from the selected launch context, so the required hostile inherited value is not cleared before either Codex or Claude auditor execution. (scenarios: auditor-setting-and-launch)
   - lib/kogen/harness/codex.ex: Codex auditor launch removes several inherited variables but not KOGEN_HARNESS_HOME.
   - lib/kogen/harness/claude.ex: Claude auditor launch likewise uses expert_removed_environment, which omits KOGEN_HARNESS_HOME.
   - .kogen/intents/approved/shaping-audit-jev-and-auditor/scenarios.yaml: R2 requires no KOGEN_HARNESS_HOME in the auditor environment.
5. An audit without --auditor can report ready when the auditor layer is not-run, contrary to R9. Additionally, the auditor layer result omits the required launched and dropped fields, so R10 and the stated auditor report shape cannot be satisfied. (scenarios: auditor-runs-and-findings)
   - lib/kogen/shaping_audit.ex: readiness/3 treats auditor status not-run as all-good when --auditor is false.
   - lib/kogen/shaping_audit/auditor.ex: Auditor.to_run_result/3 and base_result/2 omit required launched and dropped fields.
   - .kogen/intents/approved/shaping-audit-jev-and-auditor/scenarios.yaml: R9 requires not-run to yield not_ready; R10 requires dropped.findings and the auditor layer metadata.
- F6 (open): Open: assumption-without-reason findings are still disputable, contrary to the approved F6 contract.
   - lib/kogen/shaping_audit/questions.ex: Questions.findings creates assumption-without-reason through Finding.new without a mechanical override.
   - lib/kogen/shaping_audit/finding.ex: The mechanical rule list omits assumption-without-reason.

- jev-contract-questions: needs_rework — Needs rework because explicit main/2 env values are not an exclusive boundary; absent values fall back to process environment.
- question-gate-routes-questions: needs_rework — Needs rework because the controller/citation finding messages do not match the approved exact messages.
- questions-md-states: needs_rework — Needs rework because structural question findings are disputable and the technical gate message also differs from the approved wording.
- auditor-setting-and-launch: needs_rework — Needs rework because KOGEN_HARNESS_HOME is not removed from auditor launch environments.
- auditor-runs-and-findings: needs_rework — Needs rework because not-run audits can yield ready and required auditor metadata fields are absent.

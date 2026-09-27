# Open Review findings after Build U7f6BbQ5Rz4_9qBSbTlJhH_t (last attempt, verdict rework)

1. A paid-target login rejection has a reason beginning `make <target>`, but terminal_details/2 does not pass `stop_category: environment`. The unchanged prefix table therefore labels its owner status and report `integrity`. Pass the explicit environment category for this stop. (scenarios: login-rejected-is-environment, every-stop-writes-a-report)
   - lib/kogen/build.ex: terminal_details/2 adds next_command but no stop_category for a paid login rejection; stop/3 falls back to stop_category(reason).
   - lib/kogen/build.ex: stop_category/1 has no make-target login prefix and falls through to integrity.
   - .kogen/intents/approved/failure-reports/risks.yaml: Paid login stops require category environment.
2. A readiness error names the login hint in its reason, but no code extracts that hint into report details. Its report has next_command null instead of the required login command. Populate the command for readiness environment stops. (scenarios: every-stop-writes-a-report)
   - lib/kogen/build.ex: Readiness errors pass only stop_category to stop/3; stop/3 passes those details to the report.
   - lib/kogen/build/failure_report.ex: record_failure/4 sets next_command only from details["next_command"].
   - .kogen/intents/approved/failure-reports/scenarios.yaml: Readiness report requires next_command mix kogen.claude.login.
3. On a second matching offline exhaustion, the report says `reshape_details` while the error message says `rebuild`; the message also repeats its report and action fields. Format the suffix once using the written report's next_action. (scenarios: every-stop-writes-a-report)
   - lib/kogen/build.ex: stop/3 formats next action from classify/1 twice and appends a second failure-report/next-action suffix.
   - lib/kogen/build/failure_report.ex: record_failure/4 changes a repeated item signature's next_action to reshape_details.
4. The two wrapped login fixtures do not contain the specified real and synthetic excerpts or their required provenance. Replace them with the approved source excerpts and metadata so the replay proves the intended markers. (scenarios: login-rejected-is-environment)
   - .kogen/intents/approved/failure-reports/INTENT.md: The real excerpt must carry XfjCRM76YhocUjkONmFsNAZC provenance and end with its recorded result event.
   - test/support/provider_tails/xfjcrm76_claude_oauth_revoked.json: The file instead names a fixture build and fixture record and contains a newly simplified event.
   - .kogen/intents/approved/failure-reports/INTENT.md: The synthetic excerpt must be labelled synthetic and retain the source stream provenance and two events.
   - test/support/provider_tails/synthetic_codex_refresh_failed.json: The file lacks synthetic: true, uses fixture provenance, and contains one event.
5. A direct frame call with only a stage and log adds reproduce, contrary to the approved contract. Keep reproduce on failing run_stage frames while omitting it for this call form and replay. (scenarios: rework-prompt-inlines-first-failure)
   - scripts/check/offline.py: failure_signature_frame(stage, output) defaults include_reproduce to true and inserts a fallback command.
   - .kogen/intents/approved/failure-reports/INTENT.md: The stage-and-log-only call must omit reproduce.
6. The approved offline evidence is largely absent: there are no required fixture Build report tests, login replay path, prompt and frame assertions, or captured candidates listing with a report. The required README guidance is also absent. Add the specified tests, fake-tail support and documentation; the passing check receipt cannot establish behaviors that its tests do not exercise. (scenarios: every-stop-writes-a-report, login-rejected-is-environment, rework-prompt-inlines-first-failure, candidates-show-the-report)
   - .kogen/intents/approved/failure-reports/INTENT.md: The required Build-path, login, prompt, frame and listing tests are specified here.
   - test/kogen/failure_report_test.exs: The added file has only writer and two-category unit tests; it has no fixture Build assertions.
   - test/kogen/candidates_command_test.exs: The existing tests contain no new report listing assertion.
   - test/support/fake_claude: The fake has no FAKE_CLAUDE_FAIL_TAIL branch to replay the Claude excerpt.
   - README.md: No failure-report or reproduce documentation was added; inspected current contents.

- every-stop-writes-a-report: needs_rework — Needs rework. I inspected report writing, stop paths and the added tests. Readiness loses next_command, paid login gets the wrong category, and repeated-signature messages disagree with reports. I did not run the missing fixture Build matrix.
- login-rejected-is-environment: needs_rework — Needs rework. I checked marker logic, terminal classification and both fixtures. Paid login falls to integrity and the fixtures do not satisfy the specified provenance and excerpt contract. I did not run a login Build replay.
- rework-prompt-inlines-first-failure: needs_rework — Needs rework. I checked persistence, rendering and frame generation. The direct frame call violates the required omission of reproduce, and the specified prompt and frame tests were not added. I did not run a resumed fixture Build.
- candidates-show-the-report: needs_rework — Needs rework. The listing branch appears to print the required fields, but I found no required report-bearing task test or captured output and did not run a hand-written-record listing. Add that proof.
- existing-expectations-kept: satisfied — Satisfied for the existing expectations I checked: the listed existing tests were unedited, the prefix table remains, and the Candidate-bound check receipt passed. I did not independently rerun the gate.

# Open Review findings after Build yGlcdznTGAkqQSrfhXIq-go2 (last attempt, verdict rework)

- F1 (open): open: required verification remains incomplete. The implementation and broad tests are present, but exact presented-summary contents, chain reset after an allowed stop, elapsed decision invariance, and the complete flow-state matrix are not independently asserted as required by H7, H16, H17, and H25.
   - .kogen/intents/approved/shaping-stop-hook/scenarios.yaml: The required H7 presented-summary exact output, H16 chain reset, H17 elapsed invariance, and complete H25 flow matrix remain specified here.
   - test/kogen/shaping_audit_hook_test.exs: The candidate has broad hook coverage, but no exact H7 summary assertion or H16 test; the elapsed test only checks key names, and the flow hook test covers only asking-no-answers and not-ready states.
   - test/kogen/shaping_audit_flow_test.exs: The flow Stop-hook test exercises only two states rather than the approved H25 matrix.

- stop-hook-decides-every-stop: needs_rework — needs_rework: implementation paths were inspected and broad tests exist, but the approved exact verification surface remains incomplete for presented summary contents, chain reset, elapsed invariance, and the complete flow matrix.
- shaping-flow-prompts-and-codex-launch: satisfied — satisfied: the prompt contract, Codex-only hook/search argv, role-specific helper descriptions, launch environment, and byte-identity requirements are implemented and covered by focused tests.
- smoke-fixture-without-auditor: satisfied — satisfied: the pinned smoke fixture transform, auditor removal, low helper profiles, unchanged bounds and correlation checks, manifest isolation, preserved controls, and hostile environment cleanup are implemented and tested.

Feature: Shape refuses acceptance that contradicts its own contract or the unchanged code

  Shape gives every new candidate that readiness accounted for to an independent read-only contract review.
  Kogen keeps only findings whose quotes it finds in the cited files, refuses a candidate only for findings an
  independent confirmation confirms, and publishes correct candidates unchanged. The three regressions are the
  recurrences of 2 Nov 2026 (Builds f63f53ce, fea7d4b7 and c8537207) in miniature: each keeps its real
  contradicting expectation verbatim, and the fixture project holds the unchanged code or text it contradicts.

  Scenario: K-STEP-FILE-COLLISION's contradicting acceptance is refused at Shape and its correction is published
    When the contract shaper shapes "k-step-file-collision" with its contradicting package and then its correction
    Then the "k-step-file-collision" shape exited with status 0 after the requests "shaper, review, confirmation, shaper, review, shaper"
    And every "k-step-file-collision" contract review and confirmation request offered exactly read_file, list_files, search_text and its own submit tool
    And the first "k-step-file-collision" contract review request instructions contain:
      """
      Read-only: use only read_file, list_files and search_text, then call submit_contract_review once.
      A scenario that fails only because the requested feature is missing is not a finding.
      When unsure, report nothing.
      """
    And the first "k-step-file-collision" contract review request carried the candidate files and these readiness observations:
      """
      features/steps/greet-a.js has not landed
      greet-b has not been shaped
      """
    And the "k-step-file-collision" confirmation request listed exactly these findings:
      """
      1. scenario: Two Intents with the same step text land in either order | expectation: features/steps/k_step_file_collision_steps.js: [own(A).split('/').pop(), own(B).split('/').pop(), 'integration_steps.js'] | contract: features/steps/README.md: Cucumber step definitions for Kogen acceptance scenarios. | why: kogen init wrote and committed features/steps/README.md, a project step file that stays, so the steps folder on main also holds README.md and this exact list cannot match.
      2. scenario: Shape refuses a package that borrows another Intent's step text | expectation: features/steps/k_step_file_collision_steps.js: '.kogen/intents/greet-b/intent.md must not be published' | contract: spec/prose/02-shaping.md: the files of that attempt stay | why: The borrowing package is written before the step self-check refuses it, and Shape keeps the files of a refused attempt, so intent.md exists after the refusal.
      """
    And the feedback to "k-step-file-collision" submission 1 was exactly:
      """
      Contract check: 2 acceptance expectation(s) contradict the Intent or code it keeps unchanged, so no correct implementation can pass them; nothing was published. Correct each expectation, or the Intent where the Intent is what is wrong, so that a correct implementation passes; do not delete or weaken a scenario to pass this check. Resubmitting this candidate unchanged is refused again.
      - Two Intents with the same step text land in either order | expectation: features/steps/k_step_file_collision_steps.js: [own(A).split('/').pop(), own(B).split('/').pop(), 'integration_steps.js'] | contract: features/steps/README.md: Cucumber step definitions for Kogen acceptance scenarios. | why: kogen init wrote and committed features/steps/README.md, a project step file that stays, so the steps folder on main also holds README.md and this exact list cannot match. | confirmed: features/steps/README.md is committed at HEAD and the Intent keeps project step files, so the folder always lists it.
      - Shape refuses a package that borrows another Intent's step text | expectation: features/steps/k_step_file_collision_steps.js: '.kogen/intents/greet-b/intent.md must not be published' | contract: spec/prose/02-shaping.md: the files of that attempt stay | why: The borrowing package is written before the step self-check refuses it, and Shape keeps the files of a refused attempt, so intent.md exists after the refusal. | confirmed: Shape keeps the files of a refused attempt, so the borrowing package's intent.md is present after its refusal.
      """
    And the feedback to "k-step-file-collision" submission 2 was readiness observations, not a refusal
    And the published "k-step-file-collision" package is its correction
    And the "k-step-file-collision" contract_review events were:
      | result  | findings | evidenced | confirmed |
      | refused | 3        | 2         | 2         |
      | clean   | 0        | 0         | 0         |
    And the "k-step-file-collision" shaping events record 1 submission_refused event with gate "contract_review"

  Scenario: S-ROADMAP-AUTO's contradicting acceptance is refused at Shape and its correction is published
    When the contract shaper shapes "s-roadmap-auto" with its contradicting package and then its correction
    Then the "s-roadmap-auto" shape exited with status 0 after the requests "shaper, review, confirmation, shaper, review, shaper"
    And every "s-roadmap-auto" contract review and confirmation request offered exactly read_file, list_files, search_text and its own submit tool
    And the first "s-roadmap-auto" contract review request carried the candidate files and these readiness observations:
      """
      studio roadmap context kogen printed nothing: fixtures/kogen/roadmap-context.json is missing
      """
    And the "s-roadmap-auto" confirmation request listed exactly these findings:
      """
      1. scenario: Proposals and tasks are planned, and agent context carries the projection | expectation: .kogen/intents/s-roadmap-auto/acceptance.feature: {"path": "projection.lanes.2.items[].draft", "value": [{"state": "active", "order_position": 1}, null, null]} | contract: .kogen/intents/s-roadmap-auto/intent.md: | `task` | task ID / latest content title / caller-reported `state.status` | `mode`, `holds`, `next_action`, `build` | | why: The planned lane holds proposal, proposal, task; the contract gives draft to proposals only, so the task item has no draft key and reading draft on every item fails.
      2. scenario: Proposals and tasks are planned, and agent context carries the projection | expectation: .kogen/intents/s-roadmap-auto/acceptance.feature: [{"path": "roadmap.projection", "same": "projection"}] | contract: cli/cmd/runtime.go: published = encodeJSONReferences(result) | why: The unchanged Go CLI wraps agent context as {format,value,references}, so the projection is at value.roadmap.projection, never at a top-level roadmap.projection.
      """
    And the feedback to "s-roadmap-auto" submission 1 was exactly:
      """
      Contract check: 2 acceptance expectation(s) contradict the Intent or code it keeps unchanged, so no correct implementation can pass them; nothing was published. Correct each expectation, or the Intent where the Intent is what is wrong, so that a correct implementation passes; do not delete or weaken a scenario to pass this check. Resubmitting this candidate unchanged is refused again.
      - Proposals and tasks are planned, and agent context carries the projection | expectation: .kogen/intents/s-roadmap-auto/acceptance.feature: {"path": "projection.lanes.2.items[].draft", "value": [{"state": "active", "order_position": 1}, null, null]} | contract: .kogen/intents/s-roadmap-auto/intent.md: | `task` | task ID / latest content title / caller-reported `state.status` | `mode`, `holds`, `next_action`, `build` | | why: The planned lane holds proposal, proposal, task; the contract gives draft to proposals only, so the task item has no draft key and reading draft on every item fails. | confirmed: Only proposals carry draft; the task in the planned lane has mode, holds, next_action and build.
      - Proposals and tasks are planned, and agent context carries the projection | expectation: .kogen/intents/s-roadmap-auto/acceptance.feature: [{"path": "roadmap.projection", "same": "projection"}] | contract: cli/cmd/runtime.go: published = encodeJSONReferences(result) | why: The unchanged Go CLI wraps agent context as {format,value,references}, so the projection is at value.roadmap.projection, never at a top-level roadmap.projection. | confirmed: cli/cmd/runtime.go publishes encodeJSONReferences(result), whose top level is format, value and references.
      """
    And the feedback to "s-roadmap-auto" submission 2 was readiness observations, not a refusal
    And the published "s-roadmap-auto" package is its correction
    And the "s-roadmap-auto" contract_review events were:
      | result  | findings | evidenced | confirmed |
      | refused | 2        | 2         | 2         |
      | clean   | 0        | 0         | 0         |
    And the "s-roadmap-auto" shaping events record 1 submission_refused event with gate "contract_review"

  Scenario: S-DESIGN-GUIDANCE's contradicting acceptance is refused, and a refuted finding does not refuse its correction
    When the contract shaper shapes "s-design-guidance" with its contradicting package and then its correction
    Then the "s-design-guidance" shape exited with status 0 after the requests "shaper, review, confirmation, shaper, review, confirmation, shaper"
    And every "s-design-guidance" contract review and confirmation request offered exactly read_file, list_files, search_text and its own submit tool
    And the first "s-design-guidance" contract review request carried the candidate files and these readiness observations:
      """
      studio mcp serve for client owner in workspace atelier is not available: fixtures/mcp/atelier/owner.json is missing
      """
    And the "s-design-guidance" confirmation request listed exactly these findings:
      """
      1. scenario: A fresh agent exports the current design guidance | expectation: features/steps/s_design_guidance_steps.js: arguments:{artifact_id:a.artifact_id,offset,limit:4096} | contract: cli/cmd/mcp_schema.go: s["required"] = append(s["required"].([]string), "workspace_id") | why: addWorkspaceSchema makes workspace_id required on every tool schema, studio_artifact_read included, and the Intent keeps the schemas unchanged, so this read is rejected with missing properties: ["workspace_id"].
      """
    And the feedback to "s-design-guidance" submission 1 was exactly:
      """
      Contract check: 1 acceptance expectation(s) contradict the Intent or code it keeps unchanged, so no correct implementation can pass them; nothing was published. Correct each expectation, or the Intent where the Intent is what is wrong, so that a correct implementation passes; do not delete or weaken a scenario to pass this check. Resubmitting this candidate unchanged is refused again.
      - A fresh agent exports the current design guidance | expectation: features/steps/s_design_guidance_steps.js: arguments:{artifact_id:a.artifact_id,offset,limit:4096} | contract: cli/cmd/mcp_schema.go: s["required"] = append(s["required"].([]string), "workspace_id") | why: addWorkspaceSchema makes workspace_id required on every tool schema, studio_artifact_read included, and the Intent keeps the schemas unchanged, so this read is rejected with missing properties: ["workspace_id"]. | confirmed: The unchanged schema requires workspace_id and the read sends only artifact_id, offset and limit.
      """
    And the feedback to "s-design-guidance" submission 2 was readiness observations, not a refusal
    And the published "s-design-guidance" package is its correction
    And the "s-design-guidance" contract_review events were:
      | result  | findings | evidenced | confirmed |
      | refused | 1        | 1         | 1         |
      | clean   | 1        | 1         | 0         |
    And the "s-design-guidance" shaping events record 1 submission_refused event with gate "contract_review"

  Scenario: A contradiction kept to the third submission ends Shape not ready, and approval refuses the package it left
    When the contract shaper submits the contradicting "s-design-guidance" package three times and its package is put to approval
    Then the persistent "s-design-guidance" shape exited with status 1 and printed these lines in order:
      """
      intent/not_ready: the Intent is not ready to build
      - A fresh agent exports the current design guidance | expectation: features/steps/s_design_guidance_steps.js: arguments:{artifact_id:a.artifact_id,offset,limit:4096} | contract: cli/cmd/mcp_schema.go: s["required"] = append(s["required"].([]string), "workspace_id") | why: addWorkspaceSchema makes workspace_id required on every tool schema, studio_artifact_read included, and the Intent keeps the schemas unchanged, so this read is rejected with missing properties: ["workspace_id"]. | confirmed: The unchanged schema requires workspace_id and the read sends only artifact_id, offset and limit.
      """
    And the persistent shape made the requests "shaper, review, confirmation, shaper, shaper"
    And the feedback to persistent submissions 1 and 2 was exactly:
      """
      Contract check: 1 acceptance expectation(s) contradict the Intent or code it keeps unchanged, so no correct implementation can pass them; nothing was published. Correct each expectation, or the Intent where the Intent is what is wrong, so that a correct implementation passes; do not delete or weaken a scenario to pass this check. Resubmitting this candidate unchanged is refused again.
      - A fresh agent exports the current design guidance | expectation: features/steps/s_design_guidance_steps.js: arguments:{artifact_id:a.artifact_id,offset,limit:4096} | contract: cli/cmd/mcp_schema.go: s["required"] = append(s["required"].([]string), "workspace_id") | why: addWorkspaceSchema makes workspace_id required on every tool schema, studio_artifact_read included, and the Intent keeps the schemas unchanged, so this read is rejected with missing properties: ["workspace_id"]. | confirmed: The unchanged schema requires workspace_id and the read sends only artifact_id, offset and limit.
      """
    And the persistent contract_review events were:
      | result  | findings | evidenced | confirmed |
      | refused | 1        | 1         | 1         |
    And the persistent shaping events record 3 submission_refused events with gate "contract_review"
    And readiness ran 1 time in the persistent shape
    And the persistent approval card exited with status 1 and printed these lines in order:
      """
      intent/contract_contradicts: Shape's contract check found acceptance expectations that contradict the Intent or code it keeps unchanged; correct the Intent's files, or shape it again with kogen intent shape s-design-guidance <request-file>
      - A fresh agent exports the current design guidance | expectation: features/steps/s_design_guidance_steps.js: arguments:{artifact_id:a.artifact_id,offset,limit:4096} | contract: cli/cmd/mcp_schema.go: s["required"] = append(s["required"].([]string), "workspace_id") | why: addWorkspaceSchema makes workspace_id required on every tool schema, studio_artifact_read included, and the Intent keeps the schemas unchanged, so this read is rejected with missing properties: ["workspace_id"]. | confirmed: The unchanged schema requires workspace_id and the read sends only artifact_id, offset and limit.
      """
    And approving the persistent package by its full hash exited with status 1 and printed these lines in order:
      """
      intent/contract_contradicts: Shape's contract check found acceptance expectations that contradict the Intent or code it keeps unchanged; correct the Intent's files, or shape it again with kogen intent shape s-design-guidance <request-file>
      - A fresh agent exports the current design guidance | expectation: features/steps/s_design_guidance_steps.js: arguments:{artifact_id:a.artifact_id,offset,limit:4096} | contract: cli/cmd/mcp_schema.go: s["required"] = append(s["required"].([]string), "workspace_id") | why: addWorkspaceSchema makes workspace_id required on every tool schema, studio_artifact_read included, and the Intent keeps the schemas unchanged, so this read is rejected with missing properties: ["workspace_id"]. | confirmed: The unchanged schema requires workspace_id and the read sends only artifact_id, offset and limit.
      """
    And no approval marker was written for the persistent package
    And the card of the persistent package corrected by hand exited with status 5 and printed "SHA-256: "

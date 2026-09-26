# Fable review reconciliation

The human supplied screenshots of a successful read-only Fable-medium review after one invalid shell-quoting attempt. The invalid attempt is not evidence. The review did not modify files or run tests/providers.

Source inspection confirmed the primary blocker. `test/kogen/whole_suite_remediation_test.exs` passes the current worktree's changed paths into `Kogen.TestReliabilityCatalog.validate/3`; `changed_implementation?/2` then requires every row's implementation, or a qualifying preservation control, to appear in that current diff. A legitimate later Candidate does not re-edit every implementation from the completed reliability Build. The Draft now requires generation-aware validation: unchanged rows bind to a recorded admitted generation, Candidate-added/changed rows bind to the Candidate diff, and clean-checkout, stale-generation, changed-row and Gitless controls reject self-satisfaction.

The review's other supported corrections were incorporated: controller-owned verification state/tracking versus physical Candidate role roots; snapshot-only retained locators after cleanup; prompt files removed from scope; cold-offline extended to a real linked Candidate owner; existing publication limits and integrity refusals preserved; hook manifests limited to tracked admitted entries rather than ignored Python cache products; and the named state, handoff, failure-signature, Git, settlement, target-evidence, configuration and test-helper paths added where affected.

The review confirmed the original workspace outcome and recommended no additional Make target. Historical note: at the time of this review reconciliation the package was still pending approval; the final amended contract was later explicitly approved in the current conversation.

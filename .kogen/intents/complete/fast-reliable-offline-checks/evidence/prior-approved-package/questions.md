# Decisions and remaining uncertainty

- Resolved by the human: fix the complete problem, including ordinary-suite cost;
  do not stop after one fix or split the work into a fast subset and slow target.
- Resolved by the human's follow-up: there must be no synchronous test modules.
  Convert all 20, including live modules; no documented-exception escape hatch.
  Ordered operations within a single scenario remain ordered.
- Proposed measurement boundary: less than ten seconds for the complete warm
  `make check` on the shaping macOS machine; dependencies already installed.
  Cold local compilation must still succeed offline but is not subject to that
  same limit. The human confirmed this measurement boundary by approving the complete Draft.
- Technical uncertainty: the extra resumption did not reproduce in the standalone
  shaping run. Its cause is unknown. The Developer must diagnose it and retain
  exact-count assertions; this is included work, not a deferred feature.
- Feasibility risk: ordinary tests alone measured 18.5 seconds. Removing nested
  checks and terminal input dependence will not alone meet the budget. Safe fixture
  optimization or isolated process concurrency must deliver the remaining savings.
  A four-process ordinary-suite probe passed all 93 cases in 8.175 seconds; a
  compiled-code bounded lifecycle completed Shape/Build in 2.441 seconds. The
  actual combined full gate below ten seconds remains unproven. See the
  [conversion plan](async-conversion-plan.md) for measured costs and limits.
- Metadata precision: `shaping.started` records the first captured UTC clock reading
  in this conversation, after initial repository inspection; the exact launch
  timestamp was not supplied. Model and effort record the configured shaping
  launch profile from `.kogen/config.yaml`.

No public interface or UX change is proposed. The human explicitly approved this complete package in the same conversation
with “approve”. Technical feasibility and diagnosis items above remain Build
obligations; they are not permission to weaken acceptance.

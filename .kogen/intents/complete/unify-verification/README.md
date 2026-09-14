# Unify verification

Before implementation, read the [latest failed-Build diagnostic handoff](evidence/latest-build-handoff/README.md). It identifies existing implementation, observed repairs, and the remaining native-helper failure; approved requirements are unchanged.

Start with [the contract](INTENT.md), then [scenarios](scenarios.yaml), [risks and ownership](risks.yaml), and [decision provenance](decisions.md). [intent.yaml](intent.yaml) owns current identity and approval metadata. Current approval is maintained in intent.yaml; prior approvals remain historical evidence. [questions.md](questions.md) records question disposition.

Evidence: [source inspection](evidence/inspection.md), [observed stopped Build](evidence/observed-record.json), and [native Stop probe](evidence/native-stop-findings.md). The [initial Draft](evidence/historical-initial-draft/README.md) is historical, superseded proposal material. Probe sources and raw results remain editable/inspectable under evidence/; they are not production code.

Current reconciliation: [handoff integration findings and probes](evidence/handoff-integration/README.md). [The previously approved package](evidence/historical-approved-before-handoffs/README.md) preserves the pre-handoff baseline and approval.

Latest revision: [failed-Build diagnosis, source snapshot and disconfirming probes](evidence/failed-build/README.md). [Prior approved contract](evidence/historical-approved-before-failed-build/README.md).

Accepted process addition: [focused shaping regression specification](shaping-regression-spec.md), paired with the conditional guidance in the main contract.

Latest correction: [controller/hook lifetime failure](evidence/transition-failure/README.md); [previous approved package](evidence/historical-approved-before-transition-failure/README.md). Initial and resumed transition evidence is required before paid acceptance.

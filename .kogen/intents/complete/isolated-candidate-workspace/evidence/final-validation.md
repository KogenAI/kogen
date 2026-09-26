# Final deterministic validation

> Historical Draft-state receipt: the `NOT_APPROVED` line below was true when this validation ran. A later prior-conversation approval led to a failed Build; the Shaper subsequently returned the package to Draft. This receipt predates the second-Build reconciliation and is not current validation or approval evidence. The maintained current approval statement is in `../approval.md`; the historical output below is preserved unchanged.

Run from the shaped repository with the repository's supported Python path:

```text
yaml-ok .kogen/intents/drafts/isolated-candidate-workspace/intent.yaml
yaml-ok .kogen/intents/drafts/isolated-candidate-workspace/references.yaml
yaml-ok .kogen/intents/drafts/isolated-candidate-workspace/risks.yaml
yaml-ok .kogen/intents/drafts/isolated-candidate-workspace/scenarios.yaml
targets=check,cold-offline,live-native,live-reviewer-rework,live-shape-to-build
scenarios=6 risks=4
main
7c7c3426c61c80753043d51766f53ba877c22674
DRAFT_PRESENT
NOT_APPROVED
```

The commands used `YamlElixir.read_from_file/1`, `Kogen.Intent.read/2`, `Kogen.Build.Contract.load/1`, and `Kogen.Build.VerificationPlan.build/4`. The plan builder verified target catalog membership, target ordering, proof structure, and affected-path coverage by guarded paths. No paid Build verification target was run during Shaping.

After the hook-immutability review correction, validation additionally reported:

```text
codex_guarded_paths: []
codex_affected_paths: []
targets=check,cold-offline,live-native,live-reviewer-rework,live-shape-to-build
scenarios=6 risks=4
```

Thus no `.codex/**` file is authorized for implementation or listed as an affected path. The complete admitted hook tree and `.codex/hooks.json` are preservation inputs enforced by the contract and negative control.

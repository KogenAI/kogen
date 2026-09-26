**Blocking defects**

1. **`no-tracked-caches` — `.gitignore` edits are unconditionally rejected.**  
   The scenario requires modifying `.gitignore` and deleting tracked cache files ([scenarios.yaml:850-858](</Users/almirsarajcic/Areas/Kogen/kogen/.kogen/intents/drafts/build-reliability/scenarios.yaml:850>)). Although `.gitignore` appears in `may_change_guarded_paths` ([intent.yaml:45-59](</Users/almirsarajcic/Areas/Kogen/kogen/.kogen/intents/drafts/build-reliability/intent.yaml:45>)), `GuardedPaths` snapshots it specially ([guarded_paths.ex:31-42](</Users/almirsarajcic/Areas/Kogen/kogen/lib/kogen/build/guarded_paths.ex:31>)) and rejects any change before ordinary guards are checked ([guarded_paths.ex:51-67](</Users/almirsarajcic/Areas/Kogen/kogen/lib/kogen/build/guarded_paths.ex:51>)). The Build will stop before verification.  
   **Minimal fix:** defer `.gitignore` changes to a follow-up Intent/controller that explicitly supports ignore-policy migration, or remove that edit from this Draft.

2. **`controller-runs-prepare-before-paid` / `self-hosting-accounting` — the running controller cannot execute the new `prepare` field.**  
   The Draft requires prepare commands before paid dispatch ([scenarios.yaml:290-315](</Users/almirsarajcic/Areas/Kogen/kogen/.kogen/intents/drafts/build-reliability/scenarios.yaml:290>)), while the baseline risk explicitly says main “never reads `prepare` during this Build” ([risks.yaml:18-26](</Users/almirsarajcic/Areas/Kogen/kogen/.kogen/intents/drafts/build-reliability/risks.yaml:18>). Main’s loaded verifier only iterates targets ([verification.ex:238-263](</Users/almirsarajcic/Areas/Kogen/kogen/lib/kogen/build/verification.ex:238>); target execution is only `make <target>` ([verification.ex:298-313](</Users/almirsarajcic/Areas/Kogen/kogen/lib/kogen/build/verification.ex:298>)). Thus `live-shaping-smoke` can run without required setup, allowing a wrong acceptance or late live failure.  
   **Minimal fix:** require a prior Intent that lands prepare dispatch and rebaseline this Draft; otherwise defer the prepare field/scenarios and state they are only nested Candidate tests.

3. **`process-custody-teardown` / `custody-ctrl-c-without-mise` — Candidate `mise.toml` cannot affect this Build’s controller.**  
   The scenario relies on `ELIXIR_ERL_OPTIONS = "+Bd"` ([scenarios.yaml:978-983](</Users/almirsarajcic/Areas/Kogen/kogen/.kogen/intents/drafts/build-reliability/scenarios.yaml:978>)), but baseline `mise.toml` has only tool declarations ([mise.toml:1-2](</Users/almirsarajcic/Areas/Kogen/kogen/mise.toml:1>)). The self-hosting list of Candidate inputs read by the running controller omits `mise.toml` ([README.md:553-577](</Users/almirsarajcic/Areas/Kogen/kogen/README.md:553>)). Ctrl-C therefore retains baseline behavior unless an external shell setup supplies the variable.  
   **Minimal fix:** make this environment change controller-owned in a prerequisite Intent, or remove the “no BREAK menu” requirement from this Draft.

4. **Added-target `prepare` shape is not validated.**  
   The contract requires an argv/no-shell prepare ([scenarios.yaml:216-220](</Users/almirsarajcic/Areas/Kogen/kogen/.kogen/intents/drafts/build-reliability/scenarios.yaml:216>)), but `valid_entry?/1` validates no `prepare` shape ([verification_plan.ex:292-316](</Users/almirsarajcic/Areas/Kogen/kogen/lib/kogen/build/verification_plan.ex:292>)). A malformed field can pass catalog admission.  
   **Minimal fix:** validate optional `prepare` as a nonempty argv list of nonempty strings.

`shaping-smoke-target` otherwise satisfies the added-target rehearsal selector, rank/dependency, and Makefile requirements ([scenarios.yaml:481-547](</Users/almirsarajcic/Areas/Kogen/kogen/.kogen/intents/drafts/build-reliability/scenarios.yaml:481>)).
exit 0

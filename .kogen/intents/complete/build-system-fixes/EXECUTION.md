# Execution note

Builds run through `mix kogen.build`. The operator phase API used to bootstrap this repair (`kogen.phase`, `operator.ex`, `phase_state.ex`, `manual-phase.exs`) was jumpstart tooling and is removed from the product. This is the same full Intent, not a prerequisite Intent.

`optimum` remains the delivered default route; a Build may select another route explicitly (for example `codex`), and its results prove only that route. Live targets and their prepares run on the Build's selected route. Historical recovery evidence is in `recovery.yaml`.

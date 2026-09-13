# Shaping proof evidence

Start with [investigation](investigation.md), [frozen bootstrap criteria](bootstrap-criteria.md), and the [final proof result](proof-result.md). The [prototype patch](prototype.patch) is a disposable feasibility probe against the Intent's accepted baseline, not an approved implementation. The eventual Developer owns implementation and final tests.

## Refresh the bounded proof

Inputs: this directory's scripts and prototype.patch, original accepted Git object `1843dcfa`, installed project dependencies, Elixir/OTP, Python 3, Git, Make and existing offline-gate prerequisites from root README. Start in the repository root. No provider authentication or paid call is used; the fake provider is selected explicitly.

1. Set `ROLE_CONTEXT_PROBE_LOCATION` to a new absolute JSON path outside tracked source. Preserve old locations and run evidence.
2. Run `python3 <this-directory>/prepare-bootstrap.py`. It creates two independent private archived repositories, their own copied dependencies/build outputs, and applies the frozen patch only to the prototype copy. Review prototype-manifest.json and criteria before changing the experiment.
3. Run `python3 <this-directory>/shape-dispatch-probe.py` to capture actual fresh/continued Shape dispatch with small/large context files. It restores its temporary README edit even on failure.
4. Run `python3 <this-directory>/run-bootstrap.py accepted-engine`. The already loaded accepted Build drives a fake Developer that applies the prototype, then the real Stop hook executes full `make check`. Invalid handoff and source-derived Reviewer rework use the two allowed resumptions.
5. Only after inspecting a successful first phase, run `python3 <this-directory>/run-bootstrap.py prototype-engine`. It starts the freshly compiled prototype with a different linked requirement and exercises actual locator delivery through publication.
6. Run `python3 -B <this-directory>/reader-controls.py` and `python3 -B <this-directory>/linked-oracle-controls.py` for missing/stale record and fixed-source changed-requirement controls.
7. Inspect engine-identity.json, gate receipts, provider argument captures, source-derived Reviewer observations, persisted Complete records, and prompt sizes. Verify the loaded original engine stayed unchanged through the first phase, the second phase used locator prompts, invalid handoff caused exact-session resume, stale source caused rework, and repaired source alone permitted acceptance. Complete must retain original evidence bindings.

Outputs live under the unique directory referenced by ROLE_CONTEXT_PROBE_LOCATION. Preserve logs and failure causes. A stopped phase is evidence, not permission to reset/replay it: diagnose, record the correction, prepare a new unique run if needed and do not silently rerun until green. Old passing receipts do not replace new results. Generated fixtures belong only to their creating probe; no production repository files, approvals or commits are changed.

Completion means all frozen applicable criteria have inspected evidence, with the historical old-baseline failure and any current limitations stated. This proves transport and deterministic lifecycle feasibility, not general model judgment. Final feature acceptance remains the normal Developer/Stop/Review Build.

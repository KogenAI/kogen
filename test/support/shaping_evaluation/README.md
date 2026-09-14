# Compact Shaping evaluation

This directory owns the maintained fixtures, deterministic rehearsal, live driver,
capture validation, and refresh workflow for seven compact Shaping cases. Start
with the repository [README](../../../README.md) and the approved Intent when changing
the case contracts.

The examples are `normalize INPUT OUTPUT` and read-only synthetic
`slots CONNECTION`. Four fresh sessions exercise flawed and complete briefs. A fifth
fresh continuation starts from an independently frozen, test-authored unfinished
Draft. Hidden scripted choices and semantic counterexamples never enter the visible
fixture briefs. A paired stateful-guardrail evaluation adds flawed and complete
fresh sessions without replacing those five established cases.

## Maintained inputs

- `compact-fixtures-v2/` contains the source-bound CSV and availability facts,
  controls, samples, historical receipts, and their explicit limits.
- `stateful_guardrail.py` and `stateful_guardrail_control.py` own the small
  state/action/receipt-consumer fixture and its deterministic corruption,
  exhaustion, repair, and timestamp-consumer controls.
- `driver.py` prepares seven unique committed fixture repositories, freezes the
  continuation seed, launches the public Shape routes concurrently, routes only
  prescribed answers, captures completed native turns and Draft versions, and writes
  one aggregate required-evidence manifest.
- `integrity.py` and `draft_audit.ex` validate identity, source binding, turn order,
  case separation, intermediate/final Draft state, and manifest completeness.
- `semantic-counterexamples.json` is retained for independent Review. Deterministic
  code delivers it but never treats hashes or keywords as semantic acceptance.

## Development and refresh

Developers may run the focused offline tests named in
`test/kogen/shaping_evaluation_test.exs`; Kogen owns the declared `check` and `live`
targets. Offline rehearsal fakes only the external native executor boundary while
using actual fixture preparation, public launch commands, YAML parsing, reply routing,
completed-turn capture, collection, manifest forwarding, and integrity consumers.

The live owner is `test/kogen/live_shaping_evaluation_test.exs`. It preflights parser
and source prerequisites before provider dispatch, gives every case one ten-minute
envelope and at most six scripted replies, and performs no automatic case retry. All
seven case processes begin behind one barrier and may finish in any order; assembly is
canonical. Exactly one collector emits the target-evidence frame.

On the first unusable capture, preserve the original cause and partial evidence, stop
further owned dispatch, settle only owned descendants, and emit no passing manifest.
Cleanup failure is distinct. Each later owned attempt uses a fresh runtime directory;
never rewrite historical evidence or regenerate an unchanged success merely for a new
receipt. Private native originals stay outside required reader-facing evidence.

Completion requires all seven captured contracts, one validated manifest through the
existing consumer, Kogen-owned gates, and independent semantic Review. Synthetic
adapter controls do not prove real OAuth, and deterministic integrity does not prove
conversation quality.

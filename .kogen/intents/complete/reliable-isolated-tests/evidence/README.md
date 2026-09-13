# Shaping evidence — 2026-09-13

Baseline inspected: main at 0b76607a8a53131a16f02874bc248f52c6578a80,
matching minted provenance; tracked working tree clean. No implementation edits,
full gate, provider-backed test, or historical Candidate import performed.

## Observed probes

- `elixir .kogen/intents/drafts/reliable-isolated-tests/evidence/copy-probe.exs`:
  [source](copy-probe.exs), [output](copy-probe.txt). Existing directory merged;
  writing a copied link changed the disposable external sentinel; a destination
  symlink received copied files. All data was probe-owned and removed in teardown.
- `mix test .kogen/intents/drafts/reliable-isolated-tests/evidence/readiness_probe_test.exs`:
  [parent](readiness_probe_test.exs), [child](delayed_readiness.exs),
  [output](readiness-probe.txt). One passing diagnostic test reproduced the gap:
  a 2-second collection timeout cancelled a child with 3-second readiness delay,
  with no ready marker. This is evidence of current timing semantics, not a fix.
- `python3 test/support/terminal_probe.py --mode pipe -- python3 -c 'import time; time.sleep(3)'`:
  [output](terminal-probe.txt). Exit 1 incorrectly described a child that never
  reads stdin as waiting for stdin. This direct probe identifies the diagnostic
  assumption; Build must verify the actual Harness.exec_shaper pipe/PTY consumer.

The short injected delays are deterministic test conditions, not performance
measurements or proposals to raise global timeouts. Existing teardown tests were
read, not claimed as newly executed. No rerun-to-success was used.

## Reading and provenance

Root read README, config, Makefile, maintained check workflow, shaping template,
dependency/isolation/terminal helpers, their current tests and real fixture callers.
A configured Luna-low explorer read the historical partition and obligations.
Its initial report incorrectly presented inventory IDs as accepted slice decisions;
root detected the citation mismatch, requested correction and inspected original
scenario/risk/decision bytes. The helper retracted that implication. Historical
private-copy direction does not constitute approval of this new Draft or its exact
symlink policy. All proposed semantics are presented for this conversation's review.

The authoritative current baseline already has supervisor cleanup and dependency
copies. The older proposal baseline and serial progress table are historical inputs.
No conclusion here depends on a prior passing live receipt. Python's optional
PyYAML module was unavailable; YAML validation uses the repository's YamlElixir.

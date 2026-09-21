# Sequential three-pass audit and Fable diagnosis

The current Candidate's 69 manifest commands were run sequentially, three times each, with full logs retained during shaping at `/tmp/kogen-sequential-triple.r3Xk2I/`.

## Results

- 66 files: three consecutive passes.
- Ordinal 8, `test/kogen/codex_compatibility_test.exs`: pass, pass, fail; durations 359s, 343s, 49s.
- Ordinal 39, `test/kogen/live_reviewer_rework_test.exs`: fail, fail, fail; durations 4s, 5s, 4s.
- Ordinal 42, `test/kogen/live_shape_to_build_test.exs`: fail, fail, fail; durations 167s, 174s, 201s.

Fable-medium reports were retained during shaping at `/tmp/kogen-sequential-fable.2aV39c/`.

## Diagnoses

- Ordinal 8 is an intermittent production PTY-cleanup defect. Cleanup waits with the PTY master unread, allowing macOS terminal drain to block the exiting session leader until the master closes. The uncommitted longer cleanup timeout does not repair the race.
- Ordinal 39 is a deterministic fixture defect plus duplicated production parsing weakness. A legal grouped Make target rule is not inventoried by either single-target regex.
- Ordinal 42 is a deterministic fixture defect plus selector-admission gap. The fixture's check-only Makefile contradicts the copied seven-target catalog, and arbitrary files such as `Makefile` are currently admitted as offline test selectors.

The other previously contention-sensitive files passed three sequential runs. That does not erase their required structural controls; it distinguishes stress-triggered fragility from currently reproducible serial failure.

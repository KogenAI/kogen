# Latest Build failure: inspected in the existing shaping visit

Source: Shaper's new failure report and read-only inspection of
`.kogen/runtime/scenario-tracking/haO4oPYpXAWJfPh538GlEB_5/record.json`.
This is diagnostic evidence, not a contract revision or another approval.
No implementation edits or gates were run; MCP investigation remains elsewhere.

All three attempts passed Stop Check and supplied accepted handoffs. Live passed
5/8, then 7/8, then 6/8 tests. No top-level independent Review was reached.
The prior missing-install blocker is no longer the explanation. The final run
executed authenticated native Developer, resume and internal Review in its
compatibility fixture.

## Final compatibility failure

Retained fixture:
`/Users/almirsarajcic/Library/Application Support/Kogen/codex/compatibility/compatibility-1789038105482-450/fixture`

- `.kogen/runtime/root-environment.json` and `helper-environment.json` have HOME
  and all XDG paths under private `generations/...` directories.
- `hook-environment.json` correctly restores the fixture caller home and its
  XDG_CONFIG_HOME, leaving the other caller XDG values absent. All retain the
  selected Kogen CODEX_HOME.
- `compatibility-final-reviewer.json` returns rework explicitly for the root/helper
  restoration defect. Same-session failed/passed/resumed Check history, resume
  marker, helper project skill and context receipts were otherwise recognized.
- `priv/kogen/codex/compatibility/pty_driver.py:63` raised PermissionError on
  killpg(SIGKILL). Since receipt writing follows cleanup, no
  compatibility-shaping.json was written. The cause of OS denial remains unknown.
- `Compatibility.verify_evidence/1` collapses these failed requirements into
  incomplete_compatibility_evidence. The internal Reviewer is part of the fixture,
  not a top-level accepting Review of this Intent.

The other final failed test was Shape continuation parsing malformed YAML.
Read-only worker inspection found the exact artifact at
`.kogen/runtime/live-evidence/shape-to-build-36888-2183-1789038104356586416/continuation-state/continued-intent.yaml`.
Line 11 indents original shaping.effort by four spaces below the scalar model,
instead of two. Original-intent.yaml is valid and the new continuation block is
correctly indented. The continuation corrupted original provenance despite the
preservation directive; read_yaml! fails before later preservation assertions.
The preceding attempt passed this test. No private provider logs were copied.

Recommendation: resolve effective native root/helper environment restoration,
PTY teardown/receipt reliability, and generated fixture YAML before another full
Build retry. Preserve acceptance requirements; diagnose precise receipts rather
than treating a passing offline matrix as native proof. Underlying native shell
policy behavior needs a focused probe before choosing a repair.

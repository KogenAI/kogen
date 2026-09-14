> Historical reassessment of the earlier isolation-only package. The current
> managed-runtime revision is owned by ../INTENT.md and its approval receipt.
> The 9-scenario package described below was superseded, not implemented here.

# Current-main reassessment

This continuation started 2026-09-10T05:57:04.107462Z. The Shaper authorized
reassessment and subsequent approval with “Yes. Don't stop. Then approve.”
Original main/fdfaea11 provenance remains unchanged. The reassessed checkout
is main/bf68fd708a3faef0ef80883f47671f560b81a973; the tracked working tree was
clean. Only this ignored Intent package was edited during shaping.

## Findings and disposition

- Read README.md, the complete maintained draft, linked completed role-delegation,
  verification-ownership and continuation contracts, the newly completed
  scenario-tracking contract, and scripts/check/README.md.
- A bounded read-only helper using the configured worker profile,
  gpt-5.6-terra/medium, inspected current launch and lifecycle seams. It found
  no product conflict requiring a different isolation design.
- lib/kogen/harness.ex owns Developer launch/resume, separate Reviewer launch
  and the interactive Shaper Port. Their current environment injection differs;
  centralize environment construction without confusing TUI and exec flags.
  Resolve executable and authentication before sanitizing the caller environment.
- lib/kogen/build.ex supplies Developer verification policy; the sanitizer must
  preserve authoritative Kogen role, project and target values. Broadened guarded
  paths to include that file and lib/mix/tasks/kogen.shape.ex for narrow lifecycle
  wiring if needed. This is permission for isolation wiring, not a Build redesign.
- .codex/hooks.json, check.sh and verification_policy.py remain tracked hook
  sources. Restore ordinary tool environment through that path without weakening
  preflight, role gating, Candidate identity or gate ownership.
- bf68fd70 adds structured handoffs, attempt binding, scenario/risk accounting,
  retained findings and independent Review. The draft now explicitly preserves
  those contracts. Its new risks file supplies the current ownership dimensions.
- Native helpers are launched by Codex, not a Kogen helper API. Prove inherited
  isolation in the existing real lifecycle; do not build another helper launcher.
- Runtime stays below already ignored .kogen/runtime; no .gitignore change is
  needed. Generated settings, authentication artifacts and raw session material
  must not enter Complete evidence.
- Existing harness argument/role tests, Stop/policy tests, live_shape_to_build_test,
  live_test and disposable support fixtures remain the acceptance seams. Use
  async/private fixtures per scripts/check/README.md, with no recursive live gate.
  The Makefile declares check and live, the only targets this package requests.

## Tool evidence and limits

The installed CLI still reports codex-cli 0.153.4. The prior bounded probes are
retained in shaping-probes.md and were not rerun or upgraded into stronger claims.
No implementation, real credential refresh, new interactive turn or native-child
isolation probe was run in this continuation.

The official [configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference)
was fetched during reassessment. It documents file credential-store selection
and explicit shell-environment values. This supports the named control choices,
not auth-symlink refresh guarantees or hook/helper inheritance. Installed CLI
probe results remain the evidence for observed behavior; actual launcher-level
interactive, hostile-discovery and child isolation remain required live acceptance.

## Appetite

One Build with the configured two outer resumptions: shared launch policy,
generated settings, preserved session storage, narrow hook restoration, and
extensions of current fixtures. No new public commands, integration profiles,
installation, session migration, compatibility platform or recovery subsystem.

The final package is structurally checked with the repository's existing YAML,
Intent and scenario-contract readers; that check is not implementation verification
or a replacement for the future Build's check/live gates and independent Review.

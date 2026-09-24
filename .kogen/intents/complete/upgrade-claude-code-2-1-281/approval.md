# Approval

The Shaper approved Intent `upgrade-claude-code-2-1-281`
(`01a0d2df-a5da-72dd-a0a9-95702919dcb7`) in the shaping conversation that
started at 2026-09-24T10:04:27Z. The approval was recorded at 2026-09-24T10:13:48Z, against
`main` at `5b44ceb4dfb62c07296c1a799246c125f252ac69`.

The Shaper's words: "when you've prepared the thing, shaped Intent properly, and
it's ready for build. I approve it right now so we don't have to approve later."
They gave these words in the same message that settled Q1 (no speed claim) and
Q2 (set `CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT=1`). The approval was
applied to the package only after both decisions were written into it.

The Shaper also asked that `mix kogen.build upgrade-claude-code-2-1-281` run on
the default `claude` route once the in-flight `upgrade-codex-gpt-6` Build
commit lands. That starting condition is recorded in `risks.yaml`
(`codex-baseline-ordering`).

This approval grants no source, test or configuration write during Shaping.

## Operator prerequisite, performed after approval

`Kogen.ClaudeCode.installed/0` only accepts the checkout's own pinned version,
and the live targets don't install runtimes. A 2.1.281 Candidate's paid targets
therefore need a 2.1.281 runtime already staged in the managed root. On
2026-09-24, the outer driver staged it with the checkout's own installer, using
a scratch copy that changed only the pin and sha512 constants to the values in
`evidence/registry-and-binary-probe.md`. It used `stage` only, never `activate`:

- `runtimes/2.1.281-darwin-arm64` is staged and verified by `required`.
- `default.json` still says `2.1.280`, and `runtimes/2.1.280-darwin-arm64` is
  unchanged. The 2.1.280 checkout still reports `Installed: 2.1.280` and
  `logged in (claude.ai)` in the shared scope.

This is setup only. It does not prove any scenario. The Candidate's installer
must still pin these exact artifacts, and its own tests prove install behavior.

## Baseline change, before Build start

The `upgrade-codex-gpt-6` Build failed without a commit. Its only failure was the
guard check, which flagged this package's files written during that Build. The
Shaper's standing instruction for that case was to stash the Codex work and build
this Intent anyway. The Codex work is in `git stash` as
`codex-gpt-6-failed-build-2026-09-24`. This Build therefore starts from `main` at
`5b44ceb4dfb62c07296c1a799246c125f252ac69` without the Codex changes. The
`codex-baseline-ordering` risk now means only this: refresh reliability-catalog
bindings against the actual starting bytes.

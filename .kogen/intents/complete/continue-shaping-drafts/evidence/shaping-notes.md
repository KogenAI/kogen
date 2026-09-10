# Shaping investigation

Inspected against main at cf1fe21765c15c49ea1d404e312f6d070ee80472. Working tree was clean before this local ignored Draft was created.

- README.md describes interactive shaping, current configuration and gate ownership. `.kogen/config.yaml` specifies codex, shaping gpt-6-astra/low and two outer resumptions. Makefile declares check and live.
- `lib/mix/tasks/kogen.shape.ex` currently uses `run(_args)`, always mints a UUID, renders `priv/kogen/prompts/shaping.md` and launches the interactive harness. This directly explains the reported missing behavior.
- `lib/kogen/harness.ex` already supplies a fresh interactive launch with configured model/effort and KOGEN_ROLE=shaper. No new provider feature is required for the selected approach.
- `test/kogen/shape_task_test.exs`, `test/support/fake_codex_shaper`, `test/kogen/harness_args_test.exs` and the existing live Shape-to-Build fixture provide the verification seams. A configured Luna-low scout independently confirmed these findings; no code was changed by the scout.
- The external-repository-cli draft records id 01a0827f-a80d-743e-9ca9-2f990d1a5d21, an older Git baseline and original shaping provenance, but no session ID. Its questions.md explicitly parks the work pending process reassessment. It must be read as maintained context.
- Before the human clarified fresh-session behavior, a bounded read-only check of `codex resume --help` confirmed native session resumption exists, and a local metadata inspection located the example's original session. This approach was then rejected by the Shaper because current process changes should propagate. No session was resumed and no transcript was copied. Native-resume mechanics are not a dependency of this Intent.
- The selected design uses the existing fresh launch with different prompt content; no uncertain provider flag or hook behavior needs a new proof of concept. Runtime/model behavior is still covered by the declared real live fixture.

Draft creation is shaping only. No implementation or verification gates have been run for this change.

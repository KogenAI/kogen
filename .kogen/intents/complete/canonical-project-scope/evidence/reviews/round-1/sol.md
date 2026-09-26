## Findings

- [BLOCKING] `Workspace.canonical/1` is deleted, but callers outside `may_change_guarded_paths` remain; production `mix kogen.expert` and test support will fail to compile, contradicting “existing tests pass unedited.” — `.kogen/intents/drafts/canonical-project-scope/INTENT.md:14`; `lib/mix/tasks/kogen.expert.ex:132`; `test/support/workspace_fixture.ex:110` — add every caller (and boundary deps) to the guarded paths, or revise the removal.

- [BLOCKING] The prescribed legacy-selector recovery can dead-end: both login writers call `scope_name/…` before writing, so adding legacy detection there makes the recommended `mix kogen.*.login --project` command raise again. — `scenarios.yaml:25-29`; `lib/kogen/claude_code.ex:262-271`; `lib/kogen/codex/state.ex:29-33` — define and test an explicit canonical-selector write path that leaves credentials untouched.

- [BLOCKING] The offline proof can miss the Codex defect. With `KOGEN_HARNESS`, `Codex.bind/1` returns `scope: nil`, and `Codex.open/3` bypasses scope selection; Shape calls this fake path directly. A fake Build/Shape can therefore pass while a real Codex session raises. — `lib/kogen/codex.ex:28-43,61-77`; `lib/kogen/harness.ex:41-45,121-149`; `scenarios.yaml:26-35` — exercise the managed Codex fixture through the real selection path, or make the fake resolve selectors too.

- [BLOCKING] This changes authentication-scope routing, which D1 lists as a protected class; `risks.yaml` incorrectly treats it as eligible for delegated approval. — `plan/DIRECTION.md:82`; `INTENT.md:5-7`; `risks.yaml:5-8` — require explicit human approval and exclude this Intent from Studio auto-approval.

## Verdict: not ready
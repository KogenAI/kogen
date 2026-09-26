# Probe: lazy module loading versus preload (2026-09-26, clone of main 98ebcfb2)

**Mechanism** (`probe.exs`, results in `results.jsonl`)
- A running `mix run` VM, like the Build controller, edits
  `lib/kogen/build/report.ex` to add `probe_marker/0` and runs `mix compile`, as
  the Developer would.
- **PRELOAD=0:** `Kogen.Build.Report` was not loaded before the recompile, and
  afterwards the running VM **sees the Candidate function** (true). This is the
  oGaesE8P crash mechanism.
- **PRELOAD=1:** `Application.load(:kogen)` plus `Code.ensure_loaded!` for all
  modules. Report was loaded before the recompile, and the VM keeps its admission
  code: the Candidate function is **not seen** (false).

**Task-level fix** (`task-preload.diff`: 6 lines in `lib/mix/tasks/kogen.build.ex`)
- The task preloads before `Kogen.Build.run`.
- `KOGEN_PRELOAD_PROBE=1 mix kogen.build --route claude-dominant-adversarial-codex nonexistent-slug-probe`
  printed `preloaded=46 unloaded=0` and then the normal refusal (`intent.yaml
  missing: …`), exit 1, 0.34 s.
- `--route` parsing is unchanged. The clone was reverted afterwards.

**Limitations**
- It pins only `:kogen` application modules. Priv files (prompts, catalog) are
  still read from the Candidate by design (README "Self-hosting changes").
- A module missing from `Application.spec` (none today) would not be pinned.

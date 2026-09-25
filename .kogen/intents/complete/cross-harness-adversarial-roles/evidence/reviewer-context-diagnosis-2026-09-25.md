> **Historical (pre-#1, main 2909f557).** Intent #1 `bounded-reviewer-evidence` (22a2db95) fixed
> everything this file diagnoses. Its function names and line numbers (`cited_bytes/2`,
> `snapshot_references/2`, `build.ex` ~909-990, `environment.ex` 421-453, the fixture under
> `.kogen/runtime`) are obsolete. Use the current anchors in `INTENT.md` "Current HEAD anchors
> for #1", and **do not re-implement #1**.

# Why the Codex Reviewer is slow in live-reviewer-rework (2026-09-25)

Read-only diagnosis after Build `kdUszVF4Gw71QsxsppvSKc2b`, plus one small paid probe.
The raw streams are private harness logs and are cited, not copied.

## Measurements

| Run | Reviewer | Review times | Whole test |
|---|---|---|---|
| Claude route, 5 runs 09-23/24 (`live-evidence/reviewer-rework-{87451-14786,57797-15938,36569-12229,46975-6531,60640-386}`) | Claude | ~20-35 s each | ~112-120 s |
| Codex default route, 09-25 (`live-evidence/reviewer-rework-32176-3`) | Codex GPT-6 Sol, high | ~5 min, then ~16 min | killed at 1200 s |

In the final Codex review (`raw-stream-32259-18.jsonl`), 18 shell commands consumed 1.84M
input tokens. The largest single output was 706 KB: a `find` and pretty-print of the nested
`record.json`. A second output was 104 KB, another record dump.

The Claude final Reviewer (`reviewer-rework-87451-14786/.../raw-stream-87529-16.jsonl`) made 2
Bash calls, both trying `cat record.json`. The tool results were capped at 10.5 KB and 16.3 KB.
The review took ~21 s.

## Root causes (verified against source bytes)

1. **The tracking record snapshots itself (Kogen bug).** `snapshot_references` / `cited_bytes`
   (`lib/kogen/build.ex` ~1500-1550) embed base64 bytes of every path cited as evidence. When
   a Reviewer cites the tracking `record.json`, the record embeds a copy of itself. In the
   nested record, attempt 0's `reference_snapshots` and `reviewer_reference_snapshots` each
   hold `record.json` at 195,464 B, next to `scenarios.yaml` 2.7 KB, `dummy.txt` 157 B and two
   proof test files of 22.7 KB and 16.8 KB. Records grow with every rework attempt (307 KB to
   1.07 MB observed).
2. **The Reviewer gets the raw record path as its only pointer to most evidence.**
   `task_context` / `reviewer_context` in `lib/kogen/build.ex` provide `tracking_path`. The
   compact controller report (`Kogen.Build.Report`, ~1.8 KB) covers only the handoff. The
   prompt forbids copying the whole record into helper packets, but not dumping it into the
   Reviewer's own context.
3. **Tool output reaches the model differently on each harness.** Claude Code's Bash tool
   caps results at ~10-16 KB. Codex truncates by default, but its history is re-sent each
   step. Kogen sets no Codex output limit (`lib/kogen/codex/environment.ex` config_args
   ~421-453).
4. **Reviewer reads are not confined.** Every Codex role runs with
   `--dangerously-bypass-approvals-and-sandbox` (`lib/kogen/harness/codex.ex` `@common_flags`).
   Live fixtures live inside the real repo's `.kogen/runtime/`
   (`test/support/live_reviewer_rework_fixture.ex:52`, `test/kogen/live_shape_to_build_test.exs:115`,
   `test/kogen/live_test.exs:314`). The final Codex Reviewer ran
   `find /Users/.../kogen/.kogen/runtime -path '*live-reviewer-rework*'`, outside its fixture.
5. **The final Reviewer also waited ~2.5 min on two gpt-6-luna helpers.** This comes from the
   Developer's cannot_comply notes.

## Probe: Codex `tool_output_token_limit` (paid, 2 small runs)

Personal Codex CLI 0.156.1, `codex exec --ephemeral -s read-only -m gpt-6-luna` at low effort.
Prompt: run `seq 1 60000` (349 KB of output) and report what was seen.

| Setting | Model saw truncation | Input tokens | Wall |
|---|---|---|---|
| `-c tool_output_token_limit=1000` | yes | 37,864 | 18.7 s |
| default (control) | yes | 56,920 | 14.3 s |

The key exists and reduces what enters context. Codex already truncates by default. What
multiplies the cost is many steps over a bloated record. The first attempt of this probe hung
waiting on stdin and was discarded, not counted.

## Limitations

- Only one Codex-Reviewer run (cycle 2) has been dissected. Cycle 3's run of the same
  fixture passed in 494 s (`live-evidence/reviewer-rework-89413-10306`), so duration is highly
  variable. The earlier statement that cycle 3 was similar was wrong.
- How much each cause contributes to the wall time is inferred from tokens and command
  counts, not measured separately.

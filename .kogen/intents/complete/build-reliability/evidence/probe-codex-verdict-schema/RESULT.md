# Probe: Codex per-launch verdict schema and exec-resume re-ask (2026-09-26)

**Setup**
- Clone of main 98ebcfb2 with the same mini-project and prompts as the Claude probe.
- Kogen's own path: `Kogen.Codex.open/2` and `launch_context/1` (managed runtime
  and scope), then `Kogen.Harness.Codex.reviewer_args/2` (`gpt-6-sol`, high),
  plus `--output-schema` and `--output-last-message`.
- The re-ask used `exec resume <thread> -` with the same flags and
  `--output-schema`.
- First attempt: blocked by an unexpected `plugins/` directory in the shared
  scope (created 08:47 by an outside Codex run). The Shaper removed it.

**Run 1** (`run1-lookaround-rejected/`)
- The path pattern with lookaheads (`^(?!/)(?!.*(^|/)\.\.(/|$)).+$`) was rejected
  by the API. Both launch and resume failed:

      400 invalid_json_schema: "regex lookaround is not supported.
      Found at $.properties.scenarios.items.properties.evidence.items.properties.path.pattern"

- **Consequence:** the drafted pattern would fail every Codex Review. Claude
  accepts lookarounds, so a Claude-only test would not have caught this.

**Run 2** (`run2/`)
- Lookaround-free path pattern:
  `^(?:[^/.][^/]*|\.[^/.][^/]*)(?:/(?:[^/.][^/]*|\.[^/.][^/]*))*$`
  - Checked locally to accept `calc.py`, `lib/a.ex` and `.kogen/x.yaml`.
  - Checked locally to reject `/receipts/0 x`, `../calc.py`, `a/../b`, `a//b`,
    the empty string and `a/./b`.
- `receipt` is `null` or `^/receipts/[0-9]+(/.*)?$`.
- **Launch:** exit 0, 17.6 s, thread `01a0dc4b-4c36-…`.
  - **Disconfirming control:** the prompt demanded a third id `gamma-extra` and
    the paths `/receipts/0 …` and `../calc.py`. The output has exactly the 2 enum
    ids, `path: calc.py`, and `receipt: null`.
- **Re-ask:** `exec resume`, exit 0, 11.5 s, same thread id. Same `rework`
  verdict and outcomes, with only the shape corrected (locators `calc.py:2` and
  `calc.py:1`).
- **Noise:** one non-fatal stderr line, "failed to refresh available models:
  request timed out". The stream also carries the known bypass-hook-trust
  "error" items, which the Draft's signature and classifier normalization strip.

**Conclusions folded into the contract**
1. Codex `--output-schema` accepts `enum`, `minItems`, `maxItems`, a nullable
   `pattern` and lookaround-free patterns, on `exec` and on `exec resume`.
2. The schema builder must emit **lookaround-free** patterns only, one schema
   for both harnesses. An offline test asserts that no generated pattern
   contains `(?=`, `(?!`, `(?<=` or `(?<!`.
3. `resume_reviewer` for Codex = `exec resume <thread>` with the same reviewer
   flags plus `--output-schema`. This was observed to keep the thread and the
   judgement.

**Limitations**
- One sample per run.
- Ignoring the adversarial instruction is strong but not conclusive evidence of
  constrained decoding.

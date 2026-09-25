# Questions

The Shaper delegated every technical decision on 2026-09-25 ("I approve whatever
you guys decide!"). The decisions below are resolved. Each can be revised with
evidence.

1. **Where do historical record bytes go?** In an immutable, digest-bound sidecar
   next to the record (`record-versions/<sha256>.json`). Rejected: metadata only,
   which would lose the exact bytes a Reviewer inspected, contrary to README
   "Citations retain … exact inspected bytes". Source: Sol-high analysis §2.
2. **Packet bound: 64 KiB.** Measured in the last 12 records: handoff reports up
   to 10.7 KB, notes up to 3.9 KB, receipts 17-28 KB, mostly `make check`
   output. With output tails bounded, a full packet fits well under 64 KiB, far
   below the 195 KB to 2 MB record dumps. Claude Code's Bash cap (~10-16 KB)
   means a Reviewer reads it in a few calls.
3. **Codex output limit: 4000 tokens**, about Claude Code's Bash cap. It sits in
   `config_args`, so every Codex role and helper gets it. See
   `evidence/codex-output-limit-probe.md`.
4. **Superseded-objection rule:** only failed-then-passed within one attempt.
   The broader "any passing verification" rule was rejected (risk
   `objection-rule-too-broad`).
5. **Which fixtures move?** Only the Reviewer-rework fixture. The other two live
   fixtures stay in place, to avoid two more paid targets. They move in
   `isolated-candidate-workspace`.

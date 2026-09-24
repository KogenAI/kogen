# Probe: what Jev can judge in a Developer handoff (23 September 2026)

This was a root Shaping probe with real `jev-1.13.0` calls, made after the
Shaper authorized sending Kogen code to TypeSafe ("yes it's ok to send kogen's
code"). The key was read from the Keychain into the request header only. The
scripts (`jev-probe/*.py`) and the responses (`jev-probe/*.json`) are retained;
request bodies are not retained, but each is rebuilt deterministically from Git
objects by the scripts.

## Packet size from history (bytes from git, tokens estimated at 4 bytes/token; measured ratio is about 3.7)

The size of the Intent package (intent, scenarios and risks) plus the diff of
the code and tests, per completed Intent commit, was 4k–80k tokens. About half
of past Builds were above 32k. Tests make up roughly half of each diff. The
largest request actually sent was 124 KB, which came to **33,563 input tokens
and was accepted**.

## A. Judging implementation from the scenarios and the Candidate diff

For each scenario, the probe asked "implemented: yes / no /
insufficient_evidence". The state was the Approved `scenarios.yaml` plus
`git diff <build base> <Candidate tree>` over the code and tests.

The candidates came from `rehearsed-verification-plan` (base 05133eff):

| Candidate | Ground truth | Jev (choice, confidence) | Agreement |
| --- | --- | --- | --- |
| -lFrRPmL #0 (a2361f7e) | The Developer said all 4 were incomplete | no .39, no .50, no .37, **yes .24** | 3/4 |
| cDBZM4Sp #0 (c7e14bdb) | Reviewer: needs_rework, satisfied, needs_rework, satisfied | **yes .36, no .33, yes .24**, yes .46 | 1/4 |
| cDBZM4Sp #1 (4cc9fd51) | Reviewer: needs_rework, satisfied, satisfied, satisfied | no .26, **no .38**, yes .26, yes .54 | 3/4 |
| cDBZM4Sp #2 (b6fea28c), accepted | all satisfied | yes .52, **no .29**, yes .33, yes .54 | 3/4 |
| commit 7c7c3426, the same bytes as #2 | all satisfied | **no .23, no .18**, yes .23, yes .48 | 2/4 |
| selective-verification-targets, accepted | all satisfied | yes .84, insufficient .11, yes .43, insufficient .40, **no .18** | 2/5 |

Findings:

- Jev agreed with the ground truth on 14 of 25 answers. Confidence was mostly
  0.1–0.55, and every wrong answer had a confidence of 0.38 or lower.
- **Nondeterminism.** Byte-identical requests (#2 and 7c7c3426, both 124,168
  bytes and 33,563 tokens) gave different answers for `cost-ordered-plan`
  (yes .52 on one call, no .23 on the other).
- **Conclusion: Jev must not route work, or claim implementation, from a
  diff.** At a threshold high enough to be safe (for example 0.8), almost
  nothing would be routed. Below that threshold its answers are close to
  chance.
- `accepted-bound-build-evidence` was an invalid run. That package's scenarios
  use an older format, so the script sent zero questions, and Jev returned 422
  "questions should have at least 1 item". This is recorded rather than rerun.

## B. Reading the Developer's own prose

**Unfinished.** The probe asked "do the notes say part of scenario X is
unfinished?" (yes/no), with only the Developer's final message as state
(1.6k–2.3k tokens):

| Notes | Truth | Jev |
| --- | --- | --- |
| -lFrRPmL #0 (the Developer stated all 4 incomplete) | 4 × yes | 4 × yes, confidence 1.0 |
| cDBZM4Sp #2 (accepted, claims done) | 4 × no | 4 × no, confidence 0.95–1.0 |
| cDBZM4Sp #0 (claimed done; the Reviewer later found rework) | 4 × no (the notes claim done) | 4 × no, confidence 0.94–1.0 |

**Cannot comply.** The probe asked "do the notes say the approved contract for
scenario or risk X cannot be met as written?", with the rule "Unfinished work
alone is not a contract objection":

| Notes | Truth | Jev |
| --- | --- | --- |
| named-routes Bg1qobsC #1 | objection on risk `test-reliability-catalog` only | exactly that one yes (0.94); the other 15 no (at least 0.94) |
| -lFrRPmL #0 (unfinished, no objection) | none | none (at least 0.98) |
| cDBZM4Sp #2 (accepted) | none | none (at least 0.94) |

Findings:

- Jev reads what the Developer says reliably: 12 of 12 unfinished answers and
  34 of 34 objection answers were correct, with confidence of 0.94 or more.
  The packets are tiny, about 2–6k tokens, so one request for the whole
  handoff fits easily.
- Jev cannot catch unfinished work that the Developer does not mention
  (cDBZM4Sp #0). That remains the Reviewer's job.

## Limits

This was one host and a small sample: one Intent family, plus one objection
case and one extra accepted Intent. The prose samples are old JSON-handoff
messages rather than the future free prose, although the claims inside them are
prose. The numbers show how capable Jev is; they are not a calibrated
threshold.

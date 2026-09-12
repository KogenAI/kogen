# Root semantic adjudication

The coordinating Shaping Controller read all three complete `runs/*/answer.txt`
outputs and checked their claims against the frozen `CONTRACT.md` and numbered
`release_manifest.py`. This is ordinary-meaning assessment, separate from the
automatic structural/citation screen and independent of cost or model preference.

| Candidate | Conflict defect | Destructive failure defect | Legitimate duplicates | False findings | Semantic result |
| --- | --- | --- | --- | --- | --- |
| Astra low | Correct | Correct | Explicitly allowed | None | Pass |
| Sol low | Correct | Correct | Explicitly allowed | None | Pass |
| Terra medium | Correct | Correct | Explicitly allowed | None | Pass |

All three describe two otherwise valid artifacts whose alias-normalized identity
matches but whose valid digests differ. Line 18 normalizes before forming the key;
line 19 unconditionally replaces the previous entry. Each correctly predicts
success with the latter record instead of required rejection. Sol describes valid
64-character lowercase hex digests without spelling out particular characters;
that is a concrete discriminating input family, not a missing counterexample.

All three identify line 32 truncating an existing output before line 33 opens and
validates input. Astra supplies `{}`; Terra supplies malformed `[`; Sol supplies
malformed JSON, an invalid artifact, or an unreadable input. Each correctly predicts
failure with lost existing bytes, violating the contract's preservation rule. The
specific examples differ but establish the same defect. Sol's severity label
`critical` versus the others' `high` does not create a false finding; no fixed
severity taxonomy was required for this comparison.

All three reject this Candidate while explicitly allowing equal normalized
duplicates. None proposes the planted incorrect blanket duplicate ban or adds an
unsupported defect. Their cited code lines match the inspected bytes. This
semantic result supersedes any automatic screen failure for Sol; it does not
change the preserved screen output or waive a substantive requirement.

This one compact two-defect case supports comparable detection on the supplied
Candidate. It does not establish equal general reviewer reliability, exhaustive
review competence, or that Review is only summarization. Combine it with lifecycle
evidence and complete cost measurements when proposing a reversible profile.

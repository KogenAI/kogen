# Jev audit (shaping-audit-v1, jev-1.13.0), advisory

Package: `.kogen/intents/drafts/isolated-candidate-workspace`. Requests: 187. Input tokens: 227631 (about $0.0096).

| flag | scenario | text | answer |
|---|---|---|---|
| then-without-described-proof | role-write-boundary | `lsopen` and `appleevent-send` are denied. | not_described 0.92 |
| wrong-result-not-caught | write-boundary-fails-closed | a `/tmp` alias is accepted and never matches | choice=none 0.93, noul=0.11 |

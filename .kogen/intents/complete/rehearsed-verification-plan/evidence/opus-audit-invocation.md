# Opus audit invocation

The first literal invocation was attempted without stdin and returned:

```text
Error: Input must be provided either through stdin or as a prompt argument when using --print
```

The valid audit invocation used the same required executable and flags, with `evidence/opus-audit-request.md` supplied on stdin:

```sh
claude -p --dangerously-skip-permissions --setting-sources local --model opus --effort medium < .kogen/intents/drafts/rehearsed-verification-plan/evidence/opus-audit-request.md
```

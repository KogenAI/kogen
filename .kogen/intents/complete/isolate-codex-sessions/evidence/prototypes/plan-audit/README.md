# Focused plan-audit controls

Run from the repository root:

```sh
python3 -B .kogen/intents/approved/isolate-codex-sessions/evidence/prototypes/plan-audit/probe.py
```

Inputs: current `test/support/shaping_evaluation/managed_resume.py`, committed HEAD
`test/support/native_helper_fixture.ex`, and the native-helper receipt/protocol at
`.kogen/runtime/live-evidence/native-helper-21046-818-1789326000782227708/`.
Requires Python stdlib, Elixir, and existing compiled test dependencies including
Jason under `_build/test/lib/*/ebin`. Missing retained inputs mean this historical
probe cannot be reproduced; do not substitute another passing receipt.

`results.json` retains observed results and source hashes. The helper validation
runs the committed validator in a private VM against the actual receipt, followed
by an explicitly synthetic corrected-kind control. The actual Python resume
consumer executes a harmless temporary endpoint to observe environment precedence.
Temporary files are owned inside this directory and cleaned on exit. No provider
calls, production writes or aggregate gates occur. This does not demonstrate the
complete public operation, actual successful native kinds, or repaired live tests.

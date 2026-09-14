# Source-bound final-attempt controls

From repository root run `python3 -B .kogen/intents/approved/isolate-codex-sessions/evidence/prototypes/final-attempt-audit/probe.py`.
Requires Python stdlib, current hook/driver/integrity sources and the exact retained
continuation run/session named by the script. Missing historical inputs prevent
reproduction; do not substitute another session. results.json records source hashes,
observations and limitations. Temporary owned files are cleaned automatically.
No provider calls, aggregate gates or production writes occur. The hook runs as
Reviewer, never Developer. No raw conversation is copied. The environment-message
removal is a synthetic diagnostic control, not a sufficient safe implementation.

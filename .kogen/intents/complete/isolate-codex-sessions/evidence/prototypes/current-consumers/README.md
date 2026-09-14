# Current evaluation session consumer probe

Purpose: demonstrate the maintained driver’s session-location assumption using
synthetic inputs, without native/provider work. Source and SHA-256 are in
[results.json](results.json); [probe.py](probe.py) is the editable reproduction.

From the repository root run:

```sh
python3 -B .kogen/intents/drafts/isolate-codex-sessions/evidence/prototypes/current-consumers/probe.py
```

Requires Python 3 standard library and the maintained evaluation driver. The
script creates an owned temporary directory here, imports the real driver with
synthetic HOME/CODEX_HOME/runtime values, and checks managed-location failure,
personal-location success, then explicit managed-root success. It removes its
temporary inputs and restores environment values before writing concise results.
No credentials, native executables, dependencies or external services are used.

Completion is three passing assertions and the retained source-bound JSON receipt.
A changed source or failed assertion requires inspecting the new behavior; do not
alter controls to force the historical result. Do not repeat an unchanged success
for a fresh receipt. This is consumer evidence only, not launch, authentication,
combined rehearsal or Build acceptance.

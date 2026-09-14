# Managed 0.154.0 native helper capability

The exact executable SHA-256 is retained in the result files. Scripts were run
from the repository root with Python 3 stdlib. They use the retained managed
launch context from the named failed evaluation, including its existing selected
Kogen account and still-existing generated executor/profile dependencies. This is
not personal Codex authentication. Those dependencies must exist to reproduce it.

## Observations

- native_probe.py / native-results.json: unchanged managed context, no custom
  definitions; parent reports no agent_type option and makes no child calls.
  That report alone is not schema proof.
- custom_probe.py / custom-agent-results.json: temporary project-scoped standalone
  definitions for explorer/worker/default; actual native spawn calls include all
  three required kinds and the configured model/effort values.
- builtin_probe.py / builtin-control-results.json: only an unrelated custom
  capability_marker definition, leaving built-in kinds untouched; actual native
  calls again include explorer/worker/default and configured profiles.
- native-metadata.json retains runner-owned parent/child relationships, agent_role,
  observed profiles, completions and hashes. Nine sessions: three parents and six
  children. Both child-producing runs completed. No private raw logs are copied.

Conclusion: this exact runtime can execute the required kinds. Loading standalone
agent definitions changes tool availability in the tested context. Existing
agents.<role>.config_file overrides alone did not provide that behavior. Do not
replace built-in semantics with the synthetic Return OK probe definitions.

Each native script creates and cleans an owned temporary fixture. Native session
records remain in the selected Kogen scope; the retained context is read, not
regenerated. No source/test/configuration edits or aggregate gates were made.
The tests prove capability and project-scoped definition discovery, not final
production generation placement, concurrency, or full Build acceptance.

## Invalid capture experiments retained

probe.py attempted local HTTP schema capture. The first invocation lacked its
CODEX_HOME directory. Correcting that reached unauthenticated external websocket
requests rather than the configured local endpoint; an environment-override
variant did the same. 401 failures and no local requests mean no schema proof.
invalid-*.json preserve these outcomes. Do not rerun this failed capture approach
or claim it was an offline successful probe. It supplied no real API credential.

Official documentation inspected September 14:
https://learn.chatgpt.com/docs/agent-configuration/subagents
It describes standalone agent TOML definitions, required name/description/
developer_instructions, and built-in kinds. Actual native controls above establish
the version-specific observation; current docs alone are not pin compatibility proof.

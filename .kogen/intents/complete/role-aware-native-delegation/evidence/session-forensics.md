# Session forensics

The saved shaping session `01a0827f-a9e4-7813-8deb-70d12a63ac5e` received a
higher-priority `explicitRequestOnly` multi-agent policy: it could not
proactively spawn native subagents unless the user, an applicable instruction,
or a skill explicitly requested delegation. Kogen's prompt only said a native
subagent was encouraged when genuinely relevant.

The principal discovery turn took approximately 196.5 seconds. Eight shell
calls occupied about 3.0 seconds, while their serialized output was roughly
129,000 characters. The controller's input context grew from about 18,000 to
62,875 tokens. Runtime-path, hook/test, and packaging investigations included
independent seams that could have been delegated while the root continued the
product conversation.

Across three saved Kogen Developer sessions and four Reviewer sessions, the
roles issued 86 direct execution calls and zero `spawn_agent` calls. All seven
received the same explicit-request-only policy. Both Build prompts merely said
subagents were encouraged or discretionary.

These observations establish the problem and parallel/context-isolation
opportunity. They do not establish guaranteed monetary savings under a ChatGPT
subscription.

# Continue shaping existing drafts in fresh sessions

## Problem and outcome

A Shaper stops work on a draft, sometimes specifically to improve Kogen's shaping process. Today `mix kogen.shape external-repository-cli` ignores the slug and starts a new Intent. The command should instead open a fresh shaping conversation about that saved draft, using current instructions and configuration.

## Accepted decisions

The Shaper explicitly rejected resuming the original Codex conversation: doing so can retain obsolete process instructions. In this conversation the Shaper accepted a shared current role prompt with mode-specific startup instructions, current configured profiles, preservation of Intent identity and original provenance, separate continuation records, explicit treatment of old and current Git baselines, a short opening summary followed by a question about where to continue, and renewed same-conversation approval. Source: the Shaper's explanation followed by “Yes” to the proposed behavior. The Shaper subsequently explicitly approved the completed package in this same conversation.

## Scope and appetite

One Build: one Developer conversation with two configured outer resumptions. Extend the existing public Mix task, shared shaping prompt and fixture seams. Do not implement the external-repository-cli feature; it is the motivating example only.

- Zero arguments retain fresh shaping. Exactly one valid slug selects `.kogen/intents/drafts/<slug>/` and preserves its identity and directory.
- Render the current shared role instructions once, with a fresh/continuation startup section. Avoid two copied role prompts that can diverge. Continuation must not tell the controller to mint an identity or choose another slug.
- Continue through the existing fresh interactive harness path. No session lookup, transcript import or `codex resume`.
- Pass the selected draft location, its identity, recorded baseline, current checkout branch/HEAD, current harness/model/effort and visit start timestamp. Read existing maintained draft material, including questions, decisions and relevant linked evidence. Do not copy private raw Codex logs into the Intent.
- Keep original `shaping` metadata unchanged. On saving continued shaping, record an append-only `shaping_continuations` list in `intent.yaml`; each entry has harness, model, effort, started and checkout (branch/head). Record one entry per visit, not each edit. This is provenance, not an engine session ID. The launcher supplies facts and does not rewrite draft YAML before the conversation.
- Preserve `shaped_against` on launch. The controller must surface a changed baseline and discuss reassessment with the Shaper; any eventual baseline update must be an explicit shaping decision recorded with provenance. Historical metadata must not claim the new checkout was already assessed.
- Preserve accepted decisions and unfinished/parked conditions. Surface conflicts with current process or code; ask the human to resolve them. Persist accepted decisions and unresolved questions in maintained draft files so subsequent fresh sessions can continue without transcript access.
- Open with a concise account of the existing draft and unresolved work, then ask where the Shaper wants to continue. Do not automatically approve, build or implement it.
- Require explicit approval of the reviewed draft in the new conversation before moving it to approved, regardless of historical approvals.

## Input handling

Reject extra arguments, unsafe slugs, missing drafts, unreadable or malformed identity YAML, identity/slug mismatches, and missing identity, original baseline or original shaping provenance with a clear nonzero error before launch. Use the repository's slug rules and keep selection within the drafts directory. Do not require Build-ready scenarios, finalized title, or guarded-path declarations simply to continue unfinished shaping. Approved and complete Intents are outside this command's selection scope. Exact diagnostic wording is implementation discretion.

## Verification

Use the existing offline public-task fixture to capture real task dispatch, prompt text, arguments, failure-before-launch behavior and absence of startup mutations. Verify current prompt/profile propagation with changed fixture values. Extend the existing disposable live shaping fixture with one fresh continuation of a pre-existing draft, retaining evidence that it reads that draft, preserves identity and waits for current-conversation approval before proceeding through the existing lifecycle. No production draft may be approved by a test. `check` and `live` already exist; the normal Build gate ownership remains unchanged.

## Non-goals

Original-session recovery, Codex log discovery, conversation pickers, new CLI flags, reopening approved/completed Intents, automatic baseline migration, Build recovery, external repository installation, generalized draft validation, transcript storage, concurrent shaping locks, model/configuration changes and a new approval command.

## Navigation

- [Machine-readable identity](intent.yaml)
- [Acceptance scenarios](scenarios.yaml)
- [Questions and proposed details](questions.md)
- [Investigation evidence](evidence/shaping-notes.md)

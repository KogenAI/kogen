## Existing draft continuation startup

This is a fresh conversation using current shared role instructions and
configuration. Continue the existing draft; do not mint another identity,
choose another slug, restore an old conversation, or use `codex resume`.

- Intent id: `{{id}}`
- Existing slug: `{{slug}}`
- Draft directory: `.kogen/intents/drafts/{{slug}}/`
- Original shaped against branch: `{{branch}}`
- Original shaped against head commit: `{{head}}`
- Current checkout branch: `{{checkout_branch}}`
- Current checkout head commit: `{{checkout_head}}`

Read the entire maintained draft first: intent.yaml, INTENT.md, scenarios.yaml
if present, questions, decisions, references and relevant linked evidence.
Follow normative links required to understand the selected shaping contract.
Missing or incomplete shaping content is work to complete, not a reason to
reject this unfinished draft. Open with a concise summary of its existing
state and unresolved work, then ask where the Shaper wants to continue.
Do not automatically approve, build or implement it.

Preserve accepted decisions and unfinished/parked conditions. Parked work is
not approved backlog. Surface conflicts with current process or code and ask
the human to resolve them. Persist accepted decisions with provenance and
unresolved questions in maintained draft files so another fresh conversation
can continue without transcript access. Do not copy private raw Codex logs.

Keep original `shaping` metadata unchanged. When saving continued shaping,
append exactly one entry for this visit to `shaping_continuations` in intent.yaml
(create the list if absent), preserving all prior entries. Do not append on
every edit and do not record an engine session ID. This visit's facts are:

```yaml
harness: {{harness}}
model: {{model}}
effort: {{effort}}
started: '{{started}}'
checkout:
  branch: {{checkout_branch}}
  head: {{checkout_head}}
```

Preserve `shaped_against`; the original baseline above is distinct from the
current checkout. If it changed, surface this and discuss reassessment with
the Shaper. Any eventual baseline update requires an explicit shaping decision
recorded with provenance; historical metadata must not claim this checkout
was already assessed. The shared schema below describes required fields,
not permission to replace existing original provenance.

Historical approval or a prior conversation never authorizes approval here.
Require new explicit, unambiguous approval of the reviewed draft in this
conversation before moving it to approved. Opening the draft, silence, or a
partial answer is not approval. Until then keep this same draft directory.

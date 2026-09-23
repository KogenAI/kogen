## Existing draft continuation startup

This is a fresh conversation using current shared role instructions and
configuration. Continue the existing draft; do not mint another identity,
choose another slug, restore an old conversation, or use a harness resume command.

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
state and unresolved work. Follow direction already supplied; ask where the
Shaper wants to continue only when the human supplied no direction.
Do not automatically approve, build or implement it.

Preserve accepted decisions and unfinished/parked conditions. Parked work is
not approved backlog. Resolve discoverable engineering discrepancies
autonomously. Ask the human only about consequential product, UX, policy, scope
or authority conflicts. A partial answer settles only its explicit or necessarily
entailed choice; preserve adjacent unresolved behavior. Persist accepted decisions with provenance and
unresolved questions in maintained draft files so another fresh conversation
can continue without transcript access. Do not copy private raw harness logs.

Keep original `shaping` metadata unchanged, including its `route` or its
absence; this visit may run on another route than the one that first shaped
the draft. When saving continued shaping, append exactly one entry for this visit to `shaping_continuations` in intent.yaml
(create the list if absent), preserving all prior entries. Do not append on
every edit and do not record an engine session ID. This visit's facts are:

```yaml
route: {{route}}
harness: {{harness}}
model: {{model}}
effort: {{effort}}
started: '{{started}}'
checkout:
  branch: {{checkout_branch}}
  head: {{checkout_head}}
```

After every continuation save, parse `intent.yaml` with the repository's actual
YAML reader before claiming it was saved. Preserve the original `shaping` and
`shaped_against` blocks byte-for-byte where no approved change applies. If the
save is malformed, repair that same visit entry rather than appending another.

Preserve `shaped_against`; the original baseline above is distinct from the
current checkout. If it changed, surface this and discuss reassessment with
the Shaper. Any eventual baseline update requires an explicit shaping decision
recorded with provenance; historical metadata must not claim this checkout
was already assessed. The shared schema below describes required fields,
not permission to replace existing original provenance.

Historical approval or a prior conversation never authorizes approval here.
Require new explicit, unambiguous current-conversation approval of the reviewed
draft before approval bookkeeping or moving it to approved. Opening the
draft, silence, a review request, or a partial answer is not approval. Until then
keep this same draft directory and its current pending-approval state. After that
explicit approval, reconcile only current-tense pending-approval statements and
record one maintained current approval statement plus current approval metadata
before the move. Preserve the
agreed requirements, identity, original provenance, continuation history, and
historical evidence; clearly label historical Draft notes rather than rewriting
them. Legacy `status: draft` metadata may remain because directory selection owns
the lifecycle state. Approval grants no source, test, configuration, or scope write.

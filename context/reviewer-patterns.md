# Reviewer Patterns Domain — Verification Techniques for Large Structural Changes

Reviewer-specific patterns and techniques for efficiently verifying large architectural changes (role deletions, registry overhauls, enforcement rewiring). Complements `shared/rules/roles/reviewer.md` § Rule L (Test Must Exercise Changed Branch).

## Verifying Large Role-Deletion Pitches — Claim-Ledger Cross-Check

For pitches that delete a role entirely (agent template, rule files, hook guards, registry entries, test fixtures), the **Claim Ledger** pattern provides an efficient, checkable alternative to re-deriving the scope from scratch:

**Pattern:**

1. **Extract the pitch's own claims** — A well-formed role-deletion pitch carries a § Claim ledger table (example: row 1 "The role costs minutes and ~65k tokens to emit ~300 tokens"; row 9 "The backward-roll check is portable into a script — it reads git state only"; row 22 "0-of-82 downstream pitches carry frontmatter"). Each claim names a concrete, falsifiable prediction.

2. **Run each claim's proof against the actual diff** — For each row, execute the claim's stated "Real-contract probe" (the command that was run to collect evidence). Verify the **outcome** column against the actual diff:
   - Claim: "every one of the 130 files an edit surface" (probe: `git grep -l "committer" -- .`) → does the diff touch or delete entries in 130 distinct files? ✅ or ❌
   - Claim: "The backward-roll check reads only git state" (probe: search the hook source for agent-dependent lines) → does the ported script contain only git/mktemp/stat calls, no other input sources? ✅ or ❌
   - Claim: "downstream repos have no frontmatter producer" (probe: `for f in codegen/pitches/shipped/*.md; do head -1 "$f" | grep -q '^---$' …`) → does the diff add a way to generate frontmatter, or does it leave them uncovered? ❌ if uncovered.

3. **Flag contradictions loudly** — If a claim's outcome contradicts the diff (e.g., "claim says this guard is dead, but diff shows it still has live callers"), the pitch is inconsistent and must be reshaped before approval. This is faster than re-deriving the entire 130-file scope yourself.

4. **Cross-check self-referential updates** — When the diff updates the exact rules/docs the reviewer is operating under (e.g., `CLAUDE.md` roles chain, `git-readonly.md`, `no-role-spawn.md`), verify the diff **correctly updates** the self-referential text: if the pitch deletes a role, the prose citing "only the committer may commit" must flip to "the loop owns commits" or "a deterministic script commits". A stale self-reference is a direct contradiction between the pitch's stated intent and what the reviewer is reading — strong independent evidence of oversight when found.

**Benefit**: For a 130-file, 984-occurrence scope, tracing 23 claim probes against the diff is faster and more reliable than file-by-file re-derivation, and the Claim Ledger itself documents exactly what was verified.

**Scalability**: Apply this pattern whenever a pitch's Solution sketch carries a § Claim ledger table. The technique is pitch-driven, not reviewer-invented — the shaper provides the checklist; the reviewer executes it against the diff and reports pass/fail for each row.

## Trigger Keywords

verifying large role-deletion, claim-ledger cross-check, reviewer audit technique, structural change verification, self-referential update check, contradiction detection, scope re-derivation

## Update When Changing

- New large role/architecture deletion with a claim ledger table
- Reviewer guidelines on large-pitch verification
- Role-deletion or registry-overhaul shaping patterns

# Document protected dependency updates

Slug: docs-protected-dependency-changes
Model: not applicable — documentation only; no lifecycle or state change
Acceptance:
- .kogen/intents/docs-protected-dependency-changes/acceptance.feature
- features/steps/docs-protected-dependency-changes__copy.js
- features/steps/docs-protected-dependency-changes__proof/control.cjs

Add a short how-to in `docs/configuration.md` near `protect` and link to it from the protected-edit guidance in `docs/getting-started.md`. A reader who sees the Shape refusal before any Build must find the handoff from the Shape instructions, without looking for a Build ID. Only those two public docs change; no runtime behavior, refusal text or protection rules change.

## Decisions
- Explain SET-8 and LOOP-2 as they stand: ordinary dependency-only manifests and lockfiles can change in a Build while preserving checks and actual verification configuration. Being consumed by a check is not itself grounds for protection; do not advise blanket additions to or removals from `protect`. An explicitly protected combined manifest has no dependency-only exception: approval of an Intent does not grant protected-file edit permission. (evidence: spec/prose/01-project-setup.md; spec/prose/04-building.md) (source: request)
- Use the combined Mix manifest with dependencies and the alias reached by configured `mix test`, the analogous npm manifest whose script is reached by the configured check, and ordinary dependency-only Go inputs. Make whole-file protection conditional on existing explicit protection, not on the language or file name. Use only commands already supported and named by the project or its docs. (evidence: spec/prose/01-project-setup.md; docs/configuration.md; .kogen/project.yaml; test/acceptance/fixtures/projects/node-app/package.json; docs/getting-started.md) (source: request)
- Start the handoff at `shape/protected_conflict`: the CLI's named files identify which baseline to review. Revise the request to avoid the protected edit if possible. Otherwise, outside Build, review the exact dependency and lockfile diff against the current base while keeping existing test definitions protected; verify all existing checks and proposed new checks from a fresh checkout with the candidate change applied. For a new required check, review its command and actual check configuration in that baseline change and verify before enablement. Commit the reviewed change and shape on the updated base. (evidence: spec/prose/02-shaping.md; docs/getting-started.md) (source: request)
- Link back to the existing Getting Started recovery instructions for a Build stopped by a protected-file contradiction. Shape refusal starts no Build and does not require recovery. Do not turn recovery into an alternate way to grant protected-file edit permission or tell users to recover a generic interrupt. (evidence: docs/getting-started.md; spec/reference/readiness-and-custody.md; spec/prose/02-shaping.md) (source: request)

## Source comparison
- Addressed — Request's Getting Started discoverability and pre-Build distinction: the Shape guidance links to the Configuration how-to; the how-to links separately to the existing Build recovery guidance. See Decisions and the first acceptance scenario, using the SHP-4 refusal code and existing recovery command, not changing either.
- Addressed — Request's ordinary dependency work, Mix alias, npm script and Go manifest/lockfile cases, and lack of approval override: Decisions and the second scenario preserve SET-8 and LOOP-2. Examples distinguish the configured commands reaching actual check definitions from tools merely consuming dependency inputs.
- Addressed — Request's exact diff/current base, named paths, preserved test definitions, fresh checkout, verification before enabling a proposed required check, and commit then re-Shape: Decisions and the first and third scenarios capture the whole handoff, with the documented Shape command.
- Addressed — Request's existing docs and link checks: run the commands in Tests on the final candidate. Nothing in the request is intentionally omitted or superseded and no new CLI behavior, check or permission is introduced.

## Tests
- Discover and follow the link as a reader who has a Shape refusal and no Build, and distinguish separate recovery: the first scenario follows the actual Markdown links to their headings and inspects the destination guidance (scenario)
- Ordinary dependency edits versus explicitly protected Mix and npm check-definition manifests, with no approval override: the second scenario inspects the Configuration prose and examples (scenario)
- Reviewed baseline change with fresh-checkout verification and new-check review before enablement: the third scenario inspects the Configuration workflow (scenario)
- Preserve existing docs and shipped links: run the configured `no-home-paths` check, `(cd cli && GOFLAGS=-trimpath go test . -run '^TestPackageDocsList')`, and the existing archive-link check invoked by `sh packaging/package.sh` on the final candidate (existing)

## Feasibility
- The configured `no-home-paths` check, `node packaging/check-archive.cjs .`, `TestPackageDocsList` and `git diff --check` passed on the scratch documentation overlay (exit 0); the unchanged installed `kogen intent shape --help` confirmed the positional shape arguments (exit 0).
- evidence: {"id":"baseline-order-observer","kind":"observer","inputs":[".kogen/intents/docs-protected-dependency-changes/acceptance.feature",".kogen/intents/docs-protected-dependency-changes/controls.json","features/steps/docs-protected-dependency-changes__proof/control.cjs"],"observers":["features/steps/docs-protected-dependency-changes__copy.js"],"checks":[{"name":"good","command":"node features/steps/docs-protected-dependency-changes__proof/control.cjs good","exit":0,"output":"Accepted review and verification before enablement\n"},{"name":"bad","command":"node features/steps/docs-protected-dependency-changes__proof/control.cjs bad","exit":1,"output":"Rejected enablement before verification\n"}]}

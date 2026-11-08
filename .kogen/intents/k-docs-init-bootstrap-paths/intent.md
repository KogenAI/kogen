# Explain init bootstrap paths

Slug: k-docs-init-bootstrap-paths
Model: not applicable — documentation and literal drift checks have no meaningful state
Acceptance:
- .kogen/intents/k-docs-init-bootstrap-paths/acceptance.feature
- features/steps/k-docs-init-bootstrap-paths__copy.js

Clarify README.md Quickstart and docs/getting-started.md prerequisites and initialization instructions. Keep the copy short and task-first, matching k-docs-concise-task-first: run init in your Git repository, then explain the three starting states near that command. Replace the blanket requirement for an existing commit, not the clean-tree requirement for Build. Preserve existing command examples and unrelated documentation. This is documentation only; do not change init behavior.

## Decisions
- Explain that a truly empty Git worktree gets a configuration-only `Initial commit`. (source: request)
- Explain that an unborn repository with uncommitted files is rejected with `environment/no_commits`. (source: request)
- Explain that a committed repository gets `Add Kogen configuration`; commit generated runnable source first, then init adds a separate setup commit. (source: request)
- Keep the explanation short and task-first, matching k-docs-concise-task-first; brevity and task-first organization require human evaluation, not a claim of automatic verification. (source: request)

## Source comparison
- Addressed: request “README/docs state concisely” all three cases, exact commit messages and error code, through the Decisions and the acceptance rows for both README.md and docs/getting-started.md; concise task-first quality requires human evaluation as recorded in Decisions.
- Addressed: request “how generated source and the setup commit relate” through the generated-source Decision and acceptance paragraph checks; preserve the existing explanation in docs/using-kogen.md.
- Superseded source reference: request cites `lib/kogen/init.ex`; that path is absent in this Go checkout. The literal drift check instead reads the existing init contract tests in cli/consumes/kogen-setup/exit_test.go, which consume the pinned setup component. Do not recreate legacy Elixir source or edit dependency pins. Acceptance checks the two commit strings and the error class/reason against that current executable contract, rather than a dead path.
- Addressed: request “a check or test greps the docs against the strings” through the acceptance literal check; it reads real docs and the current init contract each run. No probe results or test outcomes form part of this contract.
- Omitted: no requested product behavior; Studio issue 4667a1fe-b1e2-4937-ad36-b2e48d34a878 (KOGEN-003) is tracking context, not a new runtime requirement.

## Tests
- Document all three starting states with exact literals: check README and getting-started paragraphs and current init contract literals (regression)
- Explain generated source before the separate setup commit: check both task entry documents for that relationship (regression)
- Remove the blanket existing-commit prerequisite while retaining Build guidance: inspect both entry documents and preserve unrelated instructions (regression)

## Feasibility
- none

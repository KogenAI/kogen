# Guard the release docs list against observer drift

Slug: package-docs-list-matches-observer
Model: not applicable — a read-only comparison of two lists in files; there is no state to model
Acceptance:
- .kogen/intents/package-docs-list-matches-observer/acceptance.feature
- features/steps/package-docs-list-matches-observer__steps.js

The docs that packaging/package.sh copies into the release archive are named a second time in the SHIPPED_DOCS tuple of features/steps/release_archive_public_modes.py, and no check run by a Build compares them. On 21 November a change that shipped docs/providers.md passed its own Build and then failed the release qualification scenario `Release archives own their public modes independently of copied inputs and caller umask` (spec/features/10-install-and-uninstall.feature line 99). The change adds one model-free Go test file, cli/package_docs_list_test.go, run by the existing go-test check. It reads packaging/package.sh, features/steps/release_archive_public_modes.py and the docs folder (as ../packaging/package.sh, ../features/steps/release_archive_public_modes.py and ../docs from the cli package directory) and writes nothing. No script, observer or docs text changes, and no existing file is edited.

The test fails when the file names copied by the single line of packaging/package.sh that copies docs files into `"$work/docs/"` differ from the names in the SHIPPED_DOCS tuple, in either direction, and when a copied name has no file in the docs folder. Order and duplicates inside a list do not matter. Zero or two copy lines, or no SHIPPED_DOCS tuple, is a failure, never a pass.

Failure lines the test prints, one per fault: `<name>: observer lacks it`, `<name>: script lacks it`, `<name>: docs folder has no such file`, `script has no docs copy line`, `script has <n> docs copy lines, want exactly 1`, `observer has no SHIPPED_DOCS tuple`. When a structural fault (copy line count not 1, or no tuple) exists, the structural lines are printed and the names are not compared.

## Decisions
- The test is a single new file cli/package_docs_list_test.go in package main, with a real-tree test and a fixture test whose fixtures are in-memory strings and a temporary docs folder; it adds no setting and no production code. (decision: D1, round 1) (evidence: cli/help_pages_spec_test.go; cli/release_test.go) (source: request)
- Paths are read relative to the cli package directory with ../ prefixes, as the other cli spec tests do. (decision: D2, round 1) (evidence: cli/help_pages_spec_test.go; cli/testing_rules_test.go) (source: request)
- The copy line is the non-comment line matching `cp docs/<name> ... "$work/docs/"`; names are the file names after `docs/`. The observer list is the quoted names of the line starting `SHIPPED_DOCS = (`. (decision: D3, round 1) (evidence: packaging/package.sh; features/steps/release_archive_public_modes.py; features/steps/main-health-24169a__steps.js) (source: request)
- Failure wording is fixed as listed above so that the acceptance can tell which side lacks a name; this wording is chosen here and is not stated by the request. (decision: D4, round 1) (assumption: the exact failure phrases are acceptable) (source: request)
- Acceptance compiles the cli test binary once, selects the Test functions defined in cli/package_docs_list_test.go by reading that file, and runs them with a scratch tree (copy of the real script, observer and docs, with one fault) as the parent directory of an empty cli directory, so no test name or helper API is invented. (decision: D5, round 1) (evidence: packaging/package.sh; features/steps/release_archive_public_modes.py) (source: request)

## Source comparison
- Request scenarios 1-5 (real tree, 21 November drift, observer-only name, copied name without a file, zero or two copy lines or no tuple): all addressed as acceptance scenarios against the scratch tree, plus the order and duplicates rule and a rename that keeps the counts equal.
- The failing release qualification scenario `Release archives own their public modes independently of copied inputs and caller umask` is the symptom the guard prevents; it is not edited.
- Out of scope and preserved: every existing file, packaging/check-archive.cjs, the archive layout, the docs, and other Intents' cucumber steps.

## Tests
- The copied docs equal the SHIPPED_DOCS names and exist in docs, on the real tree: Go test TestPackageDocsListMatchesObserverOnRealTree in cli/package_docs_list_test.go (integration)
- Either-direction differences, a missing docs file, zero or two copy lines and a missing tuple are rejected with named errors; order and duplicates are ignored: Go test TestPackageDocsListFixtures (unit)
- The same rules observed through a faulted scratch tree: the acceptance scenarios of this Intent (scenario)

## Feasibility
- none

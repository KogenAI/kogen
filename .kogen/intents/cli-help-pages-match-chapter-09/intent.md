# Guard printed help pages against spec drift

Slug: cli-help-pages-match-chapter-09
Model: not applicable — the change is one model-free Go test that compares fixed texts; there is no state
Acceptance:
- .kogen/intents/cli-help-pages-match-chapter-09/acceptance.feature
- features/steps/cli-help-pages-match-chapter-09__steps.js

The help pages the CLI prints exist in three hand-kept copies: the program (`cli/main.go`), the fenced blocks under CLI-3 of `spec/prose/09-cli-and-process.md`, and the byte-exact constants `topHelp`, `intentHelp` and `providerHelp` in `test/acceptance/support/handlers.js`. Nothing a Build runs compares them. This Intent adds one model-free Go test file, `cli/help_pages_spec_test.go`, run by the repository's go-test check, that fails when a printed page (`kogen`, `kogen intent`, `kogen provider`) differs by a single byte from its fenced block or from its constant. The failure names the page and quotes the first differing line from each side. A page missing from a document, or present twice there, is a failure. The file writes nothing and needs no network or model. The tests run in well under a second.

Scope: only the new file `cli/help_pages_spec_test.go`. No existing file, printed page, chapter 09 text, handlers.js text or doc changes. Nothing is replaced or removed. The change processes no collection of records, so it has no work-over-a-collection scenario.

The file holds exactly four Go tests: (1) the real-tree comparison of the three printed pages with the three fenced blocks and the three constants (it passes on the current tree); (2) a comparison helper rejects drift in a fixture copy of either document and names it (a chapter 09 fixture whose provider block lacks the line `  login                    On an interactive terminal, ask which account to use and guide the sign-in` is rejected with an error naming the page provider and quoting that line; a handlers.js fixture whose providerHelp lacks one line is rejected with an error naming providerHelp); (3) a fixture chapter 09 text with the intent block missing, and another with the provider block twice, are each rejected with an error naming that page; (4) a fixture chapter 09 text whose provider block differs from the printed page only in its final line end (no trailing LF) is rejected, because the printed page ends with one LF and the comparison is byte for byte. Fixtures are strings built inside the tests, not files.

## Decisions
- The printed pages come from the program's own help path: the `parse` function of package main returns the page text for no arguments (`kogen`), `intent` and `provider`, the same text `run` prints. (decision: D1, round 1) (constraint: the test obtains pages through the program's own help path, not by copying text) (evidence: cli/main.go; cli/help.go) (source: request)
- In `spec/prose/09-cli-and-process.md` a page's block is the fenced block directly after its label line inside the CLI-3 paragraph (label lines `` `kogen`, `kogen help`: ``, `` `kogen intent`: ``, `` `kogen provider`: ``), taken byte for byte from the line after the opening fence up to the closing fence, final line end included. Zero or more than one such block for a page is a failure. (decision: D2, round 1) (constraint: byte for byte, no trimming) (evidence: spec/prose/09-cli-and-process.md) (source: request)
- In `test/acceptance/support/handlers.js` a page's constant is the template literal of `const topHelp = `, `const intentHelp = ` and `const providerHelp = `, with the two-character escape backslash n decoded to LF; the constants contain no other escape. Zero or more than one constant of a name is a failure. (decision: D3, round 1) (constraint: byte for byte after decoding the backslash n escapes only) (evidence: test/acceptance/support/handlers.js) (source: request)
- A failure message names the page (top, intent or provider), names the document (chapter 09, or the constant name such as providerHelp) and quotes the first differing line of the printed page and of the document, or says that a side has no more lines. (decision: D4, round 1) (constraint: the failure names the page and quotes the first differing line from each side) (source: request)
- A block or constant that is missing, or that appears twice, is reported as an error naming the page, never treated as empty or resolved to its first copy. (decision: D5, round 1) (constraint: a missing or duplicate page is a failure and never a pass) (source: request)
- Acceptance builds the cli test binary once, then runs it with the working directory set to a scratch tree that holds a mutated copy of the chapter 09 text and handlers.js, so the real files are never touched. The step finds the tests of the new file by reading its `func Test...` declarations, so it does not depend on any test name, and requires that the file declares exactly four tests. (decision: D6, round 1) (constraint: the test reads the two documents by the relative paths ../spec/prose/09-cli-and-process.md and ../test/acceptance/support/handlers.js from the cli directory) (evidence: cli/testmain_test.go; cli/main.go) (assumption: the file's tests find the documents through those relative paths, which holds when go test runs in the cli directory; I ran the correct and wrong implementations in a scratch copy of the tree only) (source: request)

## Source comparison
- Request: the three printed pages equal the fenced blocks under CLI-3 and the three constants; passes on today's tree — addressed by test 1 and acceptance scenario 1 (committed state passes).
- Request: a one-space difference in another page must be caught (wrong implementation compares only top or trims) — addressed in scenario 1 by a mutated intent page.
- Request: drift names the page and quotes the line, for both documents — addressed by scenario 2 (login line of 21 Nov, providerHelp, and a line of intentHelp).
- Request: missing page and duplicate page are failures — addressed by scenario 3.
- Request: final line end compared byte for byte — addressed by scenario 4.
- Request: out of scope (existing files, printed pages, chapter 09, handlers.js, cli/parse_test.go, command-path help pages, docs) — unchanged; the one new file is the whole change.

## Tests
- The printed pages equal the chapter 09 blocks and the handlers.js constants: the real-tree test in cli/help_pages_spec_test.go (unit)
- Drift in either document is rejected naming the page and quoting the line: the fixture test in cli/help_pages_spec_test.go (unit)
- A missing or duplicated block is rejected naming the page: the fixture test in cli/help_pages_spec_test.go (unit)
- A missing final line end is rejected: the fixture test in cli/help_pages_spec_test.go (unit)
- End to end: the acceptance scenarios run the built tests of the file against mutated copies of the documents (scenario)

## Feasibility
- none

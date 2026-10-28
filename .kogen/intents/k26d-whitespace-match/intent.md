# Match across line breaks, shorten last title

Slug: k26d-whitespace-match
Model: not applicable — string comparison and one last-attempt branch; no state machine
Acceptance:
- .kogen/intents/k26d-whitespace-match/acceptance.feature
- features/steps/k26d_whitespace_steps.js
- features/steps/k26d_whitespace_driver.go

Research re-check of K26c showed Shape refusing faithful quotes because the request is hard-wrapped ("Use only the\nGo standard library." was not found for the quote "Use only the Go standard library."), and a last attempt refused only for a title longer than 50 characters. This change touches `cli/shape/decision.go`, `cli/shape/audit.go` and `cli/shape/shape.go`.

## Rules
1. Whitespace-insensitive exact matching. Wherever Shape checks that a model-supplied text is an exact substring of the request, of intent.md or of a Decisions line, both sides are first normalised: every run of whitespace (space, tab, CR, LF) becomes one space and the result is trimmed. This covers the decision check (`statement` against intent.md, each `request_quotes` entry against the request) and the request-audit coverage (`exposing_input` against Decisions lines, `quote_a`/`quote_b` against question text). Nothing else becomes fuzzy: case, punctuation and wording must still match exactly. The undefined-name rule (`definesName`) is unchanged.
2. Last-attempt title shortening. On the last attempt (the existing condition `sh.priorInvalid >= 2`), when the only problem of the accumulated package's Intent check is the lint line `title: the title must be at most 50 characters`, Kogen shortens the title itself to at most 50 characters at the last word boundary (cut after the last whole word that fits; no ellipsis; trailing punctuation and spaces removed), writes the new first line `# <title>` into intent.md and the accumulated proposals, records one event `title_shortened` with `original` (the old title text, without `# `) and `title` (the new title), and continues to readiness and publication. The approval card shows the shortened title as usual. If any other problem remains, nothing is shortened and the submission is refused as today. Earlier attempts are unchanged: the problem is fed back as today.
3. Helper names (fixed here because tests call them): `shortenTitle(title string) string` in package `shape` returns the shortened title (title text without `# `); `normalizeWhitespace(s string) string` and `containsNormalized(haystack, needle string) bool` implement rule 1.

Unchanged: no attempt budget, timeout or limit raised (gate round-trips still count), no new command, flag or output line beyond the `title_shortened` event, a genuinely unsupported or contradicting item is still refused.

## Decisions
- Normalisation collapses only whitespace runs and trims; case, punctuation and words stay exact. (source: request)
- The title fallback uses the existing last-attempt condition and only applies when the title length is the sole lint problem. (source: request)
- Event fields `original` and `title` and the helper names are fixed by this Intent because the request leaves their spelling open. (source: request)
- Shortening cuts at the last word boundary within 50 characters and trims trailing punctuation, so "Add an is-even check for integers and also reject, every string" becomes "Add an is-even check for integers and also reject". (source: request)

## Source comparison
- addressed: whitespace-insensitive matching for decision-check statement/quotes and audit coverage of exposing_input and question quotes (rule 1; scenarios 1-2). Unit scenario includes LF, CRLF, tab, double spaces, a one-word difference and a case difference that stay unsupported.
- addressed: last-attempt title shortening with `title_shortened` event, card shows the short title, attempt 1 feedback unchanged (rule 2; scenarios 3-4). The 62-character title in the scenario ends on a whole word.
- addressed: wrapcol reproduction with a scripted decision checker on the first attempt (scenario 2).
- addressed: must stay: no raised limit, no new command/flag/output line, existing tests pass (existing).
- conflicting/omitted: the audit "quotes" of Decisions lines: the request names "quotes and results in Decisions lines and questions"; this Intent normalises exposing_input, and quote_a/quote_b in questions; results use the same helper where compared against Decisions lines.

## Tests
- whitespace normalisation (LF, CRLF, tabs, double spaces; a wrong word or case still fails): add cases in `cli/shape/decision_test.go` (unit); scenario 1 (scenario)
- audit coverage across line breaks: add cases in `cli/shape/audit_test.go` (unit); scenario 1 (scenario)
- shortenTitle at the last word boundary without trailing punctuation: add cases in `cli/shape/shape_test.go` (unit); scenario 1 (scenario)
- hard-wrapped request with one-line quotes passes the decision check on the first attempt: scenario 2 (scenario)
- last-attempt title shortening with event and card, attempt-1 feedback unchanged: add native cases in `cli/shape/shape_test.go` (integration); scenarios 3-4 (scenario)
- earlier behavior of K25 to K26c: the existing tests and scenarios (existing)

## Feasibility
- evidence: {"id":"k26d-observer","kind":"observer","inputs":["features/steps/k26d_whitespace_driver.go"],"observers":["features/steps/k26d_whitespace_steps.js"],"checks":[{"name":"good","command":"\"$KOGEN_NODE\" features/steps/k26d_whitespace_steps.js --control good","exit":0,"output":"k26d observer good\n"},{"name":"bad","command":"\"$KOGEN_NODE\" features/steps/k26d_whitespace_steps.js --control bad","exit":1,"output":"k26d observer rejected bad fixtures\n"}]}

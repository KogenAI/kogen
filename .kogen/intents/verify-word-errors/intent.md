---
title: Report unknown Verify words
domains: [intent, contracts]
size: small
---
A Verify entry with an unknown kind, such as `- A1: bogus`, crashes `kogen intent check` with a FunctionClauseError. An unknown modifier, such as `test domian=intent`, is reported as a missing Verify kind with no line. Report both as lint issues that name the unknown word and its Verify line.

## Acceptance
- A1: Linting an Intent whose Verify entry has an unknown kind returns an issue that names that word and the line of the Verify entry.
- A2: Linting an Intent whose Verify entry has an unknown modifier returns an issue that names that modifier and the line of the Verify entry.
- A3: An Intent whose Verify entry is `test keep domain=intent` lints without issues.

## Verify
- A1: test domain=intent
- A2: test domain=intent
- A3: test keep domain=intent

## Notes
Parsing keeps succeeding for these entries; the problem is a lint issue, as with other unsupported Verify kinds. Use the rule name `invalid_verify`. Lint only sees `Kogen.Contracts.AcceptanceItem`, so the item needs to carry the rejected Verify word and its line; extend that contract minimally.

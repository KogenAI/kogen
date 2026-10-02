---
title: Add greetings in English and Bosnian
domains: [greeter]
size: small
---
Add `HelloApp.Greeter.greet/2` with English and Bosnian greetings. Unsupported languages return `{:error, :unsupported_language}`.

## Acceptance
- A1: `HelloApp.Greeter.greet("Almir", :en)` returns `"Hello, Almir!"`.
- A2: `HelloApp.Greeter.greet("Almir", :bs)` returns `"Zdravo, Almir!"`.
- A3: `HelloApp.Greeter.greet("Almir", :fr)` returns `{:error, :unsupported_language}`.

## Verify
- A1: test domain=greeter
- A2: test domain=greeter
- A3: test domain=greeter

## Notes
The frozen tests are in `.kogen/acceptance/greet_test.exs`.

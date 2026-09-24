# Jev credentials during Build

This is part of Draft `harden-developer-handoff`, which is **not approved**.

> Historical Draft note: the approval status above was written before approval. The Intent was approved on 2026-09-23T17:06:16Z; see `approval.md`.

## Who uses the key

- The Developer only writes code. The scenario `jev-reads-developer-notes`
  tells it exactly where the key is: the macOS Keychain item
  `ai.typesafe.api`, read when the call is made and used only in the
  `Authorization: Bearer` header.
- The Developer's own tests use a fake Jev, with no key and no network.
- Real Jev calls happen only in the two paid targets, `live-reviewer-rework`
  and `live-shape-to-build`. Kogen's Stop verification runs them after the
  Developer finishes. The Developer is not allowed to run gate targets.

## What must be set up

- Only the Keychain item `ai.typesafe.api` on the Mac that runs the Build.
  It was checked during Shaping on 2026-09-23 and exists on this Mac. Its
  value was not read.
- Nothing else is needed: no environment variable, no config file, no login.

## If the key is missing

- **Updated after review (Shaper agreed):** the Build stops **before it
  starts**, with a clear message naming `ai.typesafe.api`, like a logged-out
  harness. The check only tests that the item exists and never reads the
  value (scenario `jev-key-required-before-build`).
- If Jev fails during a Build (timeout, errors, rejected key, rate limit,
  `max_tokens_exceeded`), the Build goes to the Reviewer with "Jev
  unavailable" noted.
- Both paid targets also need TypeSafe to be up. A Jev outage there shows up
  as a failed paid target.

## HTTP client

Kogen has no HTTP client yet. The Developer may add a small library such as
`Req` (`mix.exs` and `mix.lock` are guarded paths), which needs internet access
during the Build to fetch it. It may instead use Erlang's built-in `:httpc`
with verified TLS, which needs no download.

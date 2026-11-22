Feature: Chat Completions streaming guidance in the providers guide
  This feature covers the Chat Completions sentence of docs/providers.md and the Go test that checks that page.

  Scenario: The provider guide describes Chat Completions as streaming and drops the obsolete claims
    Then chat-completions-streaming-docs: the provider guide describes the Chat Completions route as streaming with a first-byte wait that covers 60 seconds and has neither obsolete claim

  Scenario: The provider guide test enforces the streaming guidance and rejects the obsolete wording
    When chat-completions-streaming-docs: the Go test binary of the providers guide is compiled
    Then chat-completions-streaming-docs: the provider guide Go test passes on the page and fails when either obsolete claim or the streaming guidance is missing

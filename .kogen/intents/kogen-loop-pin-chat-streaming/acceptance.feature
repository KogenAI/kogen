Feature: The CLI proves that the vendored Kogen Loop streams Chat Completions
  This feature checks that the refreshed vendored kogen-loop is proved from the CLI package by one new Go test file.

  Scenario: The Chat Completions request body sends stream true
    Given kogen-loop-pin-chat-streaming: the CLI carries the vendored Chat Completions client
    When kogen-loop-pin-chat-streaming: the change is inspected
    Then kogen-loop-pin-chat-streaming: exactly one new Go test file is added to the cli package and no other Go file in it changes name
    And kogen-loop-pin-chat-streaming: the new tests pass on the adopted tree
    And kogen-loop-pin-chat-streaming: the new tests fail when the vendored chat.go sends stream false

  Scenario: A first byte 60 seconds late still succeeds
    Given kogen-loop-pin-chat-streaming: the CLI carries the vendored Chat Completions client
    When kogen-loop-pin-chat-streaming: the change is inspected
    Then kogen-loop-pin-chat-streaming: the new tests pass on the adopted tree
    And kogen-loop-pin-chat-streaming: the new tests fail when the vendored first byte wait is 45 seconds

  Scenario: The existing pin test still passes against the refreshed tree
    Given kogen-loop-pin-chat-streaming: the CLI carries the vendored Chat Completions client
    When kogen-loop-pin-chat-streaming: the change is inspected
    Then kogen-loop-pin-chat-streaming: the pin test is unchanged and TestLoopPin passes

Feature: Lock down the Claude Code runtime platform refusal
  This feature adds direct Go test coverage for UnsupportedMessage, not a change to platform support or installation.

  Background:
    Given claude-runtime-unsupported-platform-test: the unmodified Claude Code runtime package tests pass

  Scenario: Refusal identifies the rejected Windows target
    Then claude-runtime-unsupported-platform-test: the tests expecting "Kogen's Claude Code runtime supports macOS on Apple Silicon and Linux x86-64 only, not windows/amd64" for "windows" and "amd64" reject "Kogen's Claude Code runtime supports macOS on Apple Silicon and Linux x86-64 only"

  Scenario: Refusal identifies both supported platforms
    Then claude-runtime-unsupported-platform-test: the tests expecting "Kogen's Claude Code runtime supports macOS on Apple Silicon and Linux x86-64 only, not windows/amd64" for "windows" and "amd64" reject "Kogen's Claude Code runtime supports macOS on Apple Silicon only, not windows/amd64"

  Scenario: Direct macOS call retains the same refusal form
    Then claude-runtime-unsupported-platform-test: the tests expecting "Kogen's Claude Code runtime supports macOS on Apple Silicon and Linux x86-64 only, not darwin/arm64" for "darwin" and "arm64" reject "unknown target darwin/arm64"

  Scenario: Direct Linux call retains the same refusal form
    Then claude-runtime-unsupported-platform-test: the tests expecting "Kogen's Claude Code runtime supports macOS on Apple Silicon and Linux x86-64 only, not linux/amd64" for "linux" and "amd64" reject "unknown target linux/amd64"

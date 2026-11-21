Feature: The printed help pages match chapter 09 and the handlers constants

  This feature checks the Go tests in cli/help_pages_spec_test.go. Each scenario runs the tests of that file as a built binary against a scratch copy of the chapter 09 text and handlers.js.

  Background:
    Given cli-help-pages-match-chapter-09: the cli test binary is built

  Scenario: The real tree passes and a one-space drift in the intent page is caught
    When cli-help-pages-match-chapter-09: the help page tests run on the "none" state of the help sources
    Then cli-help-pages-match-chapter-09: cli/help_pages_spec_test.go declares exactly four tests and all of them pass
    When cli-help-pages-match-chapter-09: the help page tests run on the "one space added at the end of a line of the intent page in the chapter 09 text" state of the help sources
    Then cli-help-pages-match-chapter-09: a help page test fails
    And cli-help-pages-match-chapter-09: the failure output contains "intent"

  Scenario: Drift is rejected and named for both documents
    When cli-help-pages-match-chapter-09: the help page tests run on the "the login line missing from the provider page in the chapter 09 text" state of the help sources
    Then cli-help-pages-match-chapter-09: a help page test fails
    And cli-help-pages-match-chapter-09: the failure output contains "provider"
    And cli-help-pages-match-chapter-09: the failure output contains the provider login line
    When cli-help-pages-match-chapter-09: the help page tests run on the "the login line missing from the providerHelp constant of handlers.js" state of the help sources
    Then cli-help-pages-match-chapter-09: a help page test fails
    And cli-help-pages-match-chapter-09: the failure output contains "providerHelp"
    When cli-help-pages-match-chapter-09: the help page tests run on the "a line missing from the intentHelp constant of handlers.js" state of the help sources
    Then cli-help-pages-match-chapter-09: a help page test fails
    And cli-help-pages-match-chapter-09: the failure output contains "intentHelp"

  Scenario: A missing page and a repeated page are failures
    When cli-help-pages-match-chapter-09: the help page tests run on the "the intent page missing from the chapter 09 text" state of the help sources
    Then cli-help-pages-match-chapter-09: a help page test fails
    And cli-help-pages-match-chapter-09: the failure output contains "intent"
    When cli-help-pages-match-chapter-09: the help page tests run on the "the provider page appearing twice in the chapter 09 text" state of the help sources
    Then cli-help-pages-match-chapter-09: a help page test fails
    And cli-help-pages-match-chapter-09: the failure output contains "provider"

  Scenario: The final line end of a page is compared byte for byte
    When cli-help-pages-match-chapter-09: the help page tests run on the "the final line end missing from the provider page in the chapter 09 text" state of the help sources
    Then cli-help-pages-match-chapter-09: a help page test fails
    And cli-help-pages-match-chapter-09: the failure output contains "provider"

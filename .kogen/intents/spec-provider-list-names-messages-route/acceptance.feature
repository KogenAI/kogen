Feature: The provider list scenarios tolerate the optional Messages Route line
  This feature checks the four provider list scenarios of the ChatGPT connection feature against the output with and without the Route line.

  Scenario: The provider list assertions accept the output without the Route line
    Given spec-provider-list-names-messages-route: the four provider list scenarios are read
    Then spec-provider-list-names-messages-route: every provider list assertion accepts the output without the Route line

  Scenario: The provider list assertions accept the output with the Route line
    Given spec-provider-list-names-messages-route: the four provider list scenarios are read
    Then spec-provider-list-names-messages-route: every provider list assertion accepts the output with the Route line

  Scenario: The provider list assertions reject every other difference
    Given spec-provider-list-names-messages-route: the four provider list scenarios are read
    Then spec-provider-list-names-messages-route: every provider list assertion rejects any other difference

  Scenario: Scope is preserved
    Given spec-provider-list-names-messages-route: the four provider list scenarios are read
    Then spec-provider-list-names-messages-route: no scenario is removed or skipped and no protected path is edited

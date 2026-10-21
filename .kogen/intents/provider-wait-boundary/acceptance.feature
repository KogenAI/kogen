Feature: Bound one logical ChatGPT response wait
  Scenario Outline: A logical response expires without renewed time
    When I exercise the real provider wait in mode "<mode>" with budget 1200
    Then the provider wait outcome is "provider/unavailable" within 1000 to 1650 milliseconds
    And the provider wait observations are:
      | requests | <requests> |
      | refreshes | <refreshes> |
      | detail | ChatGPT response wait exceeded 30 minutes |
      | leaked | false |
      | unknown_failure_usage | true |
      | held_open_closed | true |
    Examples:
      | mode | requests | refreshes |
      | silent | 1 | 0 |
      | no-headers | 1 | 0 |
      | heartbeat | 1 | 0 |
      | backoff | 1 | 0 |
      | invalid-retry | 2 | 0 |
      | after-401 | 2 | 1 |
      | proactive-refresh | 1 | 1 |
      | blocked-refresh | 0 | 1 |
      | credential-lock | 0 | 0 |

  Scenario Outline: A valid completion is independent of socket close
    When I exercise the real provider wait in mode "<mode>" with budget 1200
    Then the provider wait outcome is "ok" within 0 to 650 milliseconds
    And the provider wait observations are:
      | requests | 1 |
      | refreshes | 0 |
      | text | boundary-ok |
      | usage | {"input":100,"cached":5,"output":20,"reasoning":10} |
      | known_usage | {"input":100,"cached":5,"output":20,"reasoning":10} |
      | exact_items | true |
      | leaked | false |
      | held_open_closed | true |
    Examples:
      | mode |
      | terminal-open |
      | normal |

  Scenario: Explicit cancellation does not wait for expiry
    When I exercise the real provider wait in mode "cancel" with budget 1200
    Then the provider wait outcome is "cancel/SIGINT" within 0 to 650 milliseconds
    And the provider wait observations are:
      | requests | 1 |
      | unknown_failure_usage | true |
      | held_open_closed | true |
      | leaked | false |

  Scenario Outline: Terminal markers cannot authorize incomplete tools
    When I exercise the real provider wait in mode "<mode>" with budget 1200
    Then the provider wait outcome is "<outcome>" within 0 to 650 milliseconds
    And the provider wait observations are:
      | requests | 1 |
      | returned_items | false |
      | unknown_failure_usage | true |
      | held_open_closed | true |
      | leaked | false |
    Examples:
      | mode | outcome |
      | malformed-terminal | provider/invalid_response |
      | malformed-tool | provider/invalid_response |
      | unfinished-tool | provider/invalid_response |
      | incomplete-tool | provider/refused |

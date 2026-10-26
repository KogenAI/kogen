Feature: Complete Anthropic end-turn tool batches
  Scenario Outline: Accept the complete synthetic tool turn under either successful reason
    When I exercise Anthropic complete tool turn "one" ending "<stop>"
    Then the Anthropic complete tool observations are:
      """
      {"outcome":"completed","requests":3,"attempts":1,"stop":"<stop>","marker":<marker>,"calls":[{"id":"toolu_synthetic_01","name":"read_file","input":{"path":"lib/helper.go"}}]}
      """
    Examples:
      | stop     | marker |
      | end_turn | true   |
      | tool_use | false  |

  Scenario: Preserve the complete opaque mixed batch and group parallel tool results
    When I exercise Anthropic complete tool turn "rich" ending "end_turn"
    Then the Anthropic complete tool observations are:
      """
      {"outcome":"completed","requests":3,"attempts":1,"stop":"end_turn","marker":true,"calls":[{"id":"toolu_synthetic_01","name":"read_file","input":{"path":"lib/helper.go"}},{"id":"toolu_synthetic_00","name":"read_file","input":{"path":"README.md"}}]}
      """

  Scenario: Preserve useful text-only end_turn success without the marker
    When I exercise Anthropic complete tool turn "text" ending "end_turn"
    Then the Anthropic complete tool observations are:
      """
      {"outcome":"completed","requests":1,"attempts":1,"stop":"end_turn","marker":false,"calls":[],"text":"Complete local answer"}
      """

  Scenario Outline: Reject the whole invalid batch even after a valid first call
    When I exercise Anthropic complete tool turn "<case>" ending "end_turn"
    Then the Anthropic complete tool observations are:
      """
      {"outcome":"provider/invalid_response","requests":1,"attempts":1,"stop":null,"marker":false,"calls":[]}
      """
    Examples:
      | case                |
      | array-input         |
      | blank-name          |
      | blank-id            |
      | invalid-name        |
      | invalid-id          |
      | duplicate-id        |
      | server-tool         |
      | unknown-block       |
      | unsigned-thinking   |
      | missing-redacted     |
      | gap                 |
      | malformed-input     |
      | malformed-frame     |
      | error-event         |
      | after-stop          |
      | changed-stop        |
      | empty               |

  Scenario Outline: A disallowed stop cannot become successful because it contains calls
    When I exercise Anthropic complete tool turn "one" ending "<stop>"
    Then the Anthropic complete tool observations are:
      """
      {"outcome":"<outcome>","requests":1,"attempts":1,"stop":null,"marker":false,"calls":[]}
      """
    Examples:
      | stop                          | outcome                   |
      | max_tokens                    | provider/invalid_response |
      | refusal                       | provider/invalid_response |
      | pause_turn                    | provider/invalid_response |
      | stop_sequence                 | provider/invalid_response |
      | model_context_window_exceeded | provider/context_too_long |

  Scenario Outline: Incomplete or unreadable streams stay transient under existing retries
    When I exercise Anthropic complete tool turn "<case>" ending "end_turn"
    Then the Anthropic complete tool observations are:
      """
      {"outcome":"provider/unavailable","requests":3,"attempts":3,"stop":null,"marker":false,"calls":[]}
      """
    Examples:
      | case       |
      | cut        |
      | unreadable |

  Scenario: The packaged CLI continues through an end_turn tool call and lands
    When I build with a packaged Anthropic complete tool turn
    Then the packaged Anthropic complete tool Build has:
      """
      {"exit":0,"commits":"1","candidate":"candidate\n","phases":["build","build","review","review"],"stops":["end_turn","tool_use","tool_use","tool_use"],"markers":[true,false,false,false],"gates":["setup","acceptance","check"],"approval_consumed":true}
      """

Feature: A Build stops sending builder rounds at a repeated host or base failure

  Scenario: native timeout
    When the env-failure fake builders run Builds whose configured go-test check times out or fails ordinarily
    Then the native Build whose go-test check timed out in passes 1 and 2 stopped as host_or_base_failure after pass 2 without another builder request

  Scenario: external timeout
    When the env-failure fake builders run Builds whose configured go-test check times out or fails ordinarily
    Then the external-executor Build whose go-test check timed out in passes 1 and 2 stopped as host_or_base_failure after pass 2 without another round

  Scenario: not in a row
    When the env-failure fake builders run Builds whose configured go-test check times out or fails ordinarily
    Then the native Build whose go-test check timed out in passes 1, 3 and 4 with an ordinary failure in pass 2 stopped as host_or_base_failure after pass 4

  Scenario: ordinary failure
    When the env-failure fake builders run Builds whose configured go-test check times out or fails ordinarily
    Then the native Build whose go-test check failed the same ordinary way in passes 1 and 2 got builder rounds and landed

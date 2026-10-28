Feature: Internal native Build round limits
  Scenario: Default and unsupported other-role keys leave native Build unlimited
    When the internal round-limit Build fixture runs with mode "default"
    Then the internal round-limit observation has requests 3 and outcome "landed"
    When the internal round-limit Build fixture runs with mode "other-roles"
    Then the internal round-limit observation has requests 3 and outcome "landed"

  Scenario: A continuing native builder stops at two requests
    When the internal round-limit Build fixture runs with mode "limited"
    Then the internal round-limit observation has requests 2 and outcome "stopped"

Feature: Identify failed bundled version commands
  This feature reproduces ev-70d545e5 through readiness.Run and the rendered install report.
  Zero means success and must not appear as an install failure. The fixtures use configured paths with spaces.

  Scenario: Missing configured Node identifies its path and status
    Given readiness-install-failure-details: configured version commands have outcomes "missing", 0, 0
    When readiness-install-failure-details: the install report is produced through readiness
    Then readiness-install-failure-details: the report identifies exactly these failing tools with configured paths and statuses:
      | tool     | status |
      | node     | 127    |
      | cucumber | 127    |
      | quint    | 127    |

  Scenario: Cucumber failure is distinct from successful Node and Quint
    Given readiness-install-failure-details: configured version commands have outcomes "ok", 23, 0
    When readiness-install-failure-details: the install report is produced through readiness
    Then readiness-install-failure-details: the report identifies exactly these failing tools with configured paths and statuses:
      | tool     | status |
      | node     | 0      |
      | cucumber | 23     |
      | quint    | 0      |

  Scenario: Quint failure is distinct from successful Node and Cucumber
    Given readiness-install-failure-details: configured version commands have outcomes "ok", 0, 29
    When readiness-install-failure-details: the install report is produced through readiness
    Then readiness-install-failure-details: the report identifies exactly these failing tools with configured paths and statuses:
      | tool     | status |
      | node     | 0      |
      | cucumber | 0      |
      | quint    | 29     |

  Scenario: Multiple failures aggregate without marking successful Node failed
    Given readiness-install-failure-details: configured version commands have outcomes "ok", 23, 29
    When readiness-install-failure-details: the install report is produced through readiness
    Then readiness-install-failure-details: the report identifies exactly these failing tools with configured paths and statuses:
      | tool     | status |
      | node     | 0      |
      | cucumber | 23     |
      | quint    | 29     |

  Scenario: Successful version commands preserve the successful report
    Given readiness-install-failure-details: configured version commands have outcomes "ok", 0, 0
    When readiness-install-failure-details: the install report is produced through readiness
    Then readiness-install-failure-details: the report identifies exactly these failing tools with configured paths and statuses:
      | tool     | status |
      | node     | 0      |
      | cucumber | 0      |
      | quint    | 0      |

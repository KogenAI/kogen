Feature: Reuse the real release without scenario-wide copies
  Scenario: Preserve installation coverage while reducing workspace file creation
    When I run the real install and uninstall chapter once with workspace counting
    Then all 8 chapter scenarios pass with fewer than 102166 observed workspace files and no full release copies

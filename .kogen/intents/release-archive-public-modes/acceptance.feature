Feature: Explicit public release archive permissions
  The archive owns its application permissions, not the caller or copied assets.

  Scenario: Package owner-only copied assets under both caller umasks
    When I package isolated public payloads with:
      | umask | file_mode | executable_mode | directory_mode |
      | 077   | 0644      | 0755            | 0755           |
      | 022   | 0644      | 0755            | 0755           |
    Then both public archives preserve all payload paths, bytes, types, links and executable distinctions
    And the public archive inputs and private symlink referent are unchanged and test outputs are cleaned

  Scenario: Qualify the archive observer and cleanup failure reporting
    When I run the public archive observer controls
    Then the public archive control results are:
      | control | exit | output                      |
      | good    | 0    | archive controls accepted   |
      | bad     | 1    | owner-only archive rejected |

  Scenario: Qualify lock-pinned preparation and offline npm reuse
    When I run the public npm preparation controls
    Then the public npm preparation control results are:
      | control | exit | output                               |
      | good    | 0    | offline preparation controls accepted |
      | bad     | 1    | missing offline content rejected      |

Feature: Active requires executable permission bits
  This feature exercises Active directly with a newer active version and local regular files.
  Runtime probing, version selection rules, and update installation are unchanged.

  Scenario: Fall back when the active runtime is not executable
    Given active-runtime-must-be-executable: a newer active version "2.1.319" with a regular runtime of mode "0644"
    When active-runtime-must-be-executable: Active is called for that home
    Then active-runtime-must-be-executable: the returned version and path identify the "pinned" runtime

  Scenario: Keep an executable active runtime
    Given active-runtime-must-be-executable: a newer active version "2.1.319" with a regular runtime of mode "0755"
    When active-runtime-must-be-executable: Active is called for that home
    Then active-runtime-must-be-executable: the returned version and path identify the "active" runtime

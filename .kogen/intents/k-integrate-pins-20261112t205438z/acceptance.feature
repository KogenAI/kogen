Feature: Spec follows the shaping component's tool list
  This feature checks the shaping spec expectation.

  Scenario: The protected-conflict scenario expects check_package
    Given k-integrate-pins-20261112t205438z: the spec scenario "A required protected edit is reported without creating an Intent or approval" is read
    Then k-integrate-pins-20261112t205438z: its tool expectation is "read_file, view_image, list_files, search_text, probe, documentation, propose_files, check_package, submit"

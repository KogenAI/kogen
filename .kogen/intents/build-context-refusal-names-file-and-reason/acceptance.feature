Feature: The build context refusal names the file and the one cause
  This feature runs kogen intent build is-even with the context option through the real command entry and checks the refusal line.

  Scenario: A missing file is named by its absolute path
    Given build-context-refusal-names-file-and-reason: the kogen command line package is present
    When build-context-refusal-names-file-and-reason: the context option names a "missing" file "absent.txt"
    Then build-context-refusal-names-file-and-reason: the exit code is 2
    And build-context-refusal-names-file-and-reason: the refusal line is exactly "intent/context_unavailable: <dir>/absent.txt: not found"

  Scenario: A directory is not reported as missing
    Given build-context-refusal-names-file-and-reason: the kogen command line package is present
    When build-context-refusal-names-file-and-reason: the context option names a "directory" file "notes"
    Then build-context-refusal-names-file-and-reason: the exit code is 2
    And build-context-refusal-names-file-and-reason: the refusal line is exactly "intent/context_unavailable: <dir>/notes: not a regular file"

  Scenario: The size limit is stated in bytes
    Given build-context-refusal-names-file-and-reason: the kogen command line package is present
    When build-context-refusal-names-file-and-reason: the context option names a "oversize" file "big.txt"
    Then build-context-refusal-names-file-and-reason: the exit code is 2
    And build-context-refusal-names-file-and-reason: the refusal line is exactly "intent/context_unavailable: <dir>/big.txt: larger than 262144 bytes"

  Scenario: Blank and binary files get different causes
    Given build-context-refusal-names-file-and-reason: the kogen command line package is present
    When build-context-refusal-names-file-and-reason: the context option names a "blank" file "blank.txt"
    Then build-context-refusal-names-file-and-reason: the exit code is 2
    And build-context-refusal-names-file-and-reason: the refusal line is exactly "intent/context_unavailable: <dir>/blank.txt: blank"
    When build-context-refusal-names-file-and-reason: the context option names a "binary" file "binary.bin"
    Then build-context-refusal-names-file-and-reason: the exit code is 2
    And build-context-refusal-names-file-and-reason: the refusal line is exactly "intent/context_unavailable: <dir>/binary.bin: not valid UTF-8"

  Scenario: A file of exactly 262144 bytes is still accepted
    Given build-context-refusal-names-file-and-reason: the kogen command line package is present
    When build-context-refusal-names-file-and-reason: the context option names a "exact" file "limit.txt"
    Then build-context-refusal-names-file-and-reason: stdout does not contain "intent/context_unavailable"

  Scenario: The troubleshooting guide explains the refusal
    Given build-context-refusal-names-file-and-reason: the kogen command line package is present
    Then build-context-refusal-names-file-and-reason: the troubleshooting guide has a context_unavailable entry with the six causes and the working folder

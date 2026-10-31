Feature: Shape writes long packages in bounded pieces
  Scenario Outline: Execute the bounded-piece Shape contract through real entry points
    When the long-reply Shape test "<test>" runs
    Then that long-reply Shape test passed without skipping

    Examples:
      | test                          |
      | TestProposeFilesStagesPackage |
      | TestProposeFilesRefusals      |
      | TestProposeFilesCutOffReply   |
      | TestProposeFilesDroppedStream |
      | TestProposeFilesNativeOnly    |

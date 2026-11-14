Feature: Heavy-project live release journey
  This feature checks the Studio journey settings, result handling and documentation without any live model cost.

  Scenario Outline: the journey concludes only when every stage and the final commit are real
    When kogen-release-heavy-project-journey: the journey concludes after stages "<stages>" with final commit "<commit>"
    Then kogen-release-heavy-project-journey: the conclusion exits <code> printing "<text>"

    Examples:
      | stages                                                               | commit     | code | text                                    |
      | shape=ok approve=ok build=ok verify=ok review=ok commit=ok           | good       | 0    | journey: complete                       |
      | shape=ok approve=ok build=ok verify=ok commit=ok                     | good       | 1    | journey: stage review missing           |
      | shape=ok approve=ok build=ok verify=skipped review=ok commit=ok      | good       | 1    | journey: stage verify skipped           |
      | shape=ok approve=ok build=failed verify=ok review=ok commit=ok       | good       | 1    | journey: stage build failed             |
      | shape=ok approve=ok build=ok verify=ok review=ok commit=ok           | none       | 1    | journey: no new final commit            |
      | shape=ok approve=ok build=ok verify=ok review=ok commit=ok           | no-trailer | 1    | journey: final commit lacks Kogen-Intent: probe |
      | shape=ok approve=ok build=ok verify=ok review=ok commit=ok           | no-file    | 1    | journey: final commit lacks lib/probe.ex |

  Scenario: the Studio settings pin the frozen corpus and task
    When kogen-release-heavy-project-journey: the Studio settings are sourced with environment ""
    Then kogen-release-heavy-project-journey: the settings exit 0 printing "b93ff1d6c0748d74ee410615ed07cafbb7de1f07 normalize-label-probe"
    And kogen-release-heavy-project-journey: the request names "Studio.KogenReleaseProbe.normalize_label/1" and "lib/studio/kogen_release_probe.ex" and "{:error, :invalid_type}"

  Scenario: a revision override needs a recorded corpus update
    When kogen-release-heavy-project-journey: the Studio settings are sourced with environment "KOGEN_STUDIO_REVISION=0123456789abcdef0123456789abcdef01234567"
    Then kogen-release-heavy-project-journey: the settings exit 1 printing "studio: revision override needs KOGEN_STUDIO_CORPUS_UPDATE"

  Scenario: an unreadable corpus is an explicit blocked result
    When kogen-release-heavy-project-journey: prepare_repo runs against the missing source "/nonexistent/studio.git"
    Then kogen-release-heavy-project-journey: prepare_repo exits nonzero printing "studio: blocked:"

  Scenario: the journey is wired into the maintained entry point, suite and docs
    Then kogen-release-heavy-project-journey: the wiring and documentation are in place

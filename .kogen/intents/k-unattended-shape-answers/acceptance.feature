Feature: An unattended shape leaves its questions machine-readable
  A kogen intent shape that stops on questions (exit 5) also leaves the pending questions and their
  recommended options in .kogen/local/shaping/<slug>/questions.json: the version 1 checkout facts
  envelope with kind "questions". The printed questions and exit status stay as they are, and the
  existing all: recommended input answers them, recorded in the source receipt like any other answer.
  The installed release runs without a terminal against a scripted local provider whose shaper asks
  two banner questions; the caller answers question 2, then enters all: recommended.

  Scenario: A shape that stops on questions leaves them and their recommended options in questions.json
    Given the unattended banner shape flow has run
    Then the unattended "first" shape exited with status 5
    And the unattended "first" shape printed these lines in order:
      """
      Questions for answers-demo:
      1. Which wording should the banner use?
         a) Keep the current wording
         b) Use the shorter wording (recommended)
      2. Should the banner show the unread count?
         a) Show the count (recommended)
         b) Hide the count
      Answer one per line as <n>: <letter or your words>, e.g. printf '1: b\n2: a\n' | kogen intent shape answers-demo -
      Or enter all: recommended to use every question's recommended option.
      """
    And after the unattended "first" shape the questions file holds this checkout and data:
      """
      {
        "slug": "answers-demo",
        "questions": [
          {
            "number": 1,
            "question": "Which wording should the banner use?",
            "kind": "product",
            "options": [
              {"letter": "a", "label": "Keep the current wording", "recommended": false},
              {"letter": "b", "label": "Use the shorter wording", "recommended": true}
            ],
            "recommended": "b"
          },
          {
            "number": 2,
            "question": "Should the banner show the unread count?",
            "kind": "product",
            "options": [
              {"letter": "a", "label": "Show the count", "recommended": true},
              {"letter": "b", "label": "Hide the count", "recommended": false}
            ],
            "recommended": "a"
          }
        ]
      }
      """

  Scenario: Answering some questions leaves only the still pending ones in questions.json
    Given the unattended banner shape flow has run
    Then the unattended "partial" shape exited with status 5
    And the unattended "partial" shape printed these lines in order:
      """
      Questions for answers-demo:
      1. Which wording should the banner use?
         a) Keep the current wording
         b) Use the shorter wording (recommended)
      Answer one per line as <n>: <letter or your words>, e.g. printf '1: b\n' | kogen intent shape answers-demo -
      Or enter all: recommended to use every question's recommended option.
      """
    And the unattended "partial" shape did not print the line "2. Should the banner show the unread count?"
    And after the unattended "partial" shape the questions file holds this checkout and data:
      """
      {
        "slug": "answers-demo",
        "questions": [
          {
            "number": 1,
            "question": "Which wording should the banner use?",
            "kind": "product",
            "options": [
              {"letter": "a", "label": "Keep the current wording", "recommended": false},
              {"letter": "b", "label": "Use the shorter wording", "recommended": true}
            ],
            "recommended": "b"
          }
        ]
      }
      """

  Scenario: all: recommended through the existing input answers the pending questions and the receipt records them
    Given the unattended banner shape flow has run
    Then the unattended "answered" shape exited with status 0
    And the unattended "answered" shape printed these lines in order:
      """
      Next: kogen intent approve answers-demo
      """
    And the answers-demo source receipt records one answered round with:
      """
      {
        "inputs": ["2: a\n", "all: recommended\n"],
        "answers": {"1": "b", "2": "a"},
        "resolved_answers": {"1": "Use the shorter wording", "2": "Show the count"}
      }
      """
    And the shaping state file is gone after the unattended "answered" shape
    And the questions file left by the unattended "partial" shape is gone after the unattended "answered" shape

  Scenario: The questions file is documented with Kogen's machine-readable facts and the shaping questions
    Then these maintained documents name the unattended questions file:
      | path                     | text                                       |
      | docs/checkout-facts.md   | .kogen/local/shaping/<slug>/questions.json |
      | spec/prose/02-shaping.md | .kogen/local/shaping/<slug>/questions.json |

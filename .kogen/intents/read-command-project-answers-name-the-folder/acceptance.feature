Feature: Read commands name the folder when Kogen finds no project

  This feature checks the project answers of the read commands and the troubleshooting document.

  Background:
    Given read-command-project-answers-name-the-folder: the kogen CLI built from the current sources

  Scenario: A folder that is not a Git checkout names itself
    Given read-command-project-answers-name-the-folder: a folder "plain" that is not a Git checkout
    When read-command-project-answers-name-the-folder: I run kogen "intent list --project <plain>"
    Then read-command-project-answers-name-the-folder: the exit code is 3
    And read-command-project-answers-name-the-folder: the answer is one JSON line of kind "intents" with null checkout, null data and exactly the error class "environment", reason "not_project", no paths and detail "<plain> is not a Kogen project: no Git checkout with .kogen/project.yaml here; run kogen init in the project folder, or pass --project with its path"

  Scenario: A Git checkout without project configuration gets the same sentence
    Given read-command-project-answers-name-the-folder: a Git checkout "bare" without .kogen/project.yaml
    When read-command-project-answers-name-the-folder: I run kogen "intent inspect 0a1b2c3d --project <bare>"
    Then read-command-project-answers-name-the-folder: the exit code is 3
    And read-command-project-answers-name-the-folder: the answer is one JSON line of kind "run" with null checkout, null data and exactly the error class "environment", reason "not_project", no paths and detail "<bare> is not a Kogen project: no Git checkout with .kogen/project.yaml here; run kogen init in the project folder, or pass --project with its path"

  Scenario: A missing project folder is named
    Given read-command-project-answers-name-the-folder: no folder "gone"
    When read-command-project-answers-name-the-folder: I run kogen "intent list --project <gone>"
    Then read-command-project-answers-name-the-folder: the exit code is 3
    And read-command-project-answers-name-the-folder: the answer is one JSON line of kind "intents" with null checkout, null data and exactly the error class "environment", reason "project_unavailable", no paths and detail "<gone> is not a readable directory; pass --project with the path of the project folder"

  Scenario: A relative missing project folder is made absolute
    When read-command-project-answers-name-the-folder: I run kogen "intent list --project gone-relative"
    Then read-command-project-answers-name-the-folder: the exit code is 3
    And read-command-project-answers-name-the-folder: the answer is one JSON line of kind "intents" with null checkout, null data and exactly the error class "environment", reason "project_unavailable", no paths and detail "<base>/gone-relative is not a readable directory; pass --project with the path of the project folder"

  Scenario: intent preflight outside a project names the folder
    Given read-command-project-answers-name-the-folder: a folder "plain" that is not a Git checkout
    When read-command-project-answers-name-the-folder: I run kogen "intent preflight is-even --project <plain>"
    Then read-command-project-answers-name-the-folder: the exit code is 3
    And read-command-project-answers-name-the-folder: the answer is one JSON line of kind "preflight" with null checkout, null data and exactly the error class "environment", reason "not_project", no paths and detail "<plain> is not a Kogen project: no Git checkout with .kogen/project.yaml here; run kogen init in the project folder, or pass --project with its path"

  Scenario: intent usage outside a project names the folder
    Given read-command-project-answers-name-the-folder: a folder "plain" that is not a Git checkout
    When read-command-project-answers-name-the-folder: I run kogen "intent usage --project <plain>"
    Then read-command-project-answers-name-the-folder: the exit code is 3
    And read-command-project-answers-name-the-folder: the answer is one JSON line of kind "usage" with null checkout, null data and exactly the error class "environment", reason "not_project", no paths and detail "<plain> is not a Kogen project: no Git checkout with .kogen/project.yaml here; run kogen init in the project folder, or pass --project with its path"

  Scenario: context with an unreadable project folder names the folder
    Given read-command-project-answers-name-the-folder: no folder "gone"
    When read-command-project-answers-name-the-folder: I run kogen "context --project <gone>"
    Then read-command-project-answers-name-the-folder: the exit code is 3
    And read-command-project-answers-name-the-folder: the answer is one JSON line of kind "context" with null checkout, null data and exactly the error class "environment", reason "project_unavailable", no paths and detail "<gone> is not a readable directory; pass --project with the path of the project folder"

  Scenario: The current folder is named when there is no --project
    Given read-command-project-answers-name-the-folder: a folder "plain" that is not a Git checkout
    When read-command-project-answers-name-the-folder: I run kogen "context" from the folder "plain"
    Then read-command-project-answers-name-the-folder: the exit code is 0
    And read-command-project-answers-name-the-folder: the answer is the successful context outside a project
    When read-command-project-answers-name-the-folder: I run kogen "intent list" from the folder "plain"
    Then read-command-project-answers-name-the-folder: the exit code is 3
    And read-command-project-answers-name-the-folder: the answer is one JSON line of kind "intents" with null checkout, null data and exactly the error class "environment", reason "not_project", no paths and detail "<plain> is not a Kogen project: no Git checkout with .kogen/project.yaml here; run kogen init in the project folder, or pass --project with its path"

  Scenario: The troubleshooting document tells the truth
    Then read-command-project-answers-name-the-folder: the file "docs/troubleshooting.md" contains the text "intent/not_found: Intent does not exist: is-even (looked in .kogen/intents/is-even)"
    And read-command-project-answers-name-the-folder: the file "docs/troubleshooting.md" contains the text "kogen intent list shows existing Intents;"
    And read-command-project-answers-name-the-folder: the file "docs/troubleshooting.md" does not contain the text "names no next command"
    And read-command-project-answers-name-the-folder: the file "docs/troubleshooting.md" does not contain the text "prints raw"
    And read-command-project-answers-name-the-folder: the file "docs/troubleshooting.md" contains the text "- The no-login refusal is a multi-line message"
    And read-command-project-answers-name-the-folder: the file "spec/reference/checkout-facts.md" contains the text "names the folder"

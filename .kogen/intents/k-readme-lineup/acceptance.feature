Feature: A one-screen README with the repository lineup
  README.md is cut to one screen: what Kogen is, install, a quickstart and
  "Kogen repositories" (a Mermaid lineup diagram and a 9-row table), followed by
  a "More" list. Every other section of the previous README moved unchanged
  into docs/ files that the "More" list links.

  Scenario: The README is one screen with exactly what Kogen is, install, a quickstart, the repositories and More
    Given k-readme-lineup: the repository README
    Then k-readme-lineup: the README has fewer than 120 lines
    And k-readme-lineup: the README headings are exactly:
      """
      # Kogen
      ## Install
      ## Quickstart
      ## Kogen repositories
      ## More
      """
    And k-readme-lineup: the README section "Kogen" contains "This repository is `kogen`, the command-line program that is Kogen's small core. It takes one requested feature through Shape, Build, Verify, Review and Commit in your own Git repository. For Kogen as a whole, see [kogen.dev](https://kogen.dev)."
    And k-readme-lineup: the README section "Install" contains "https://github.com/KogenAI/kogen/releases"
    And k-readme-lineup: the README section "Install" contains "sh packaging/package.sh"
    And k-readme-lineup: the README section "Install" contains "kogen provider login chatgpt"
    And k-readme-lineup: the README section "Quickstart" contains "kogen init"
    And k-readme-lineup: the README section "Quickstart" contains "kogen intent shape my-feature ../request.md"
    And k-readme-lineup: the README section "Quickstart" contains "kogen intent approve my-feature"
    And k-readme-lineup: the README section "Quickstart" contains "kogen intent build my-feature"

  Scenario: "Kogen repositories" draws the lineup as a Mermaid diagram
    Given k-readme-lineup: the repository README
    Then k-readme-lineup: the README section "Kogen repositories" has exactly one mermaid block:
      """
      flowchart TD
        kogen[kogen] -->|assembles| coordinator[kogen-coordinator]
        coordinator -->|drives| shaping[kogen-shaping]
        coordinator -->|drives| build[kogen-build]
        coordinator -->|drives| review[kogen-review]
        coordinator -->|drives| verification[kogen-verification]
        shaping -->|runs through| executor[kogen-executor]
        build -->|runs through| executor
        review -->|runs through| executor
        verification -->|runs through| executor
        executor -->|runs| loop[kogen-loop]
        setup[kogen-setup] -->|sets up| projects[your projects]
      """

  Scenario: "Kogen repositories" lists the nine repositories with their responsibility and link
    Given k-readme-lineup: the repository README
    Then k-readme-lineup: the README section "Kogen repositories" has this table:
      | Repository         | Responsibility                                                                                         | Link                                                                         |
      | kogen              | The command-line program that is Kogen's small core; it assembles the pinned components.               | [KogenAI/kogen](https://github.com/KogenAI/kogen)                           |
      | kogen-coordinator  | Kogen's coordinator: the outer workflow's authority over a target repository.                          | [KogenAI/kogen-coordinator](https://github.com/KogenAI/kogen-coordinator)   |
      | kogen-shaping      | Kogen's human-assisted shaping workflow: `kogen intent shape`, `refine` and `approve`.                 | [KogenAI/kogen-shaping](https://github.com/KogenAI/kogen-shaping)           |
      | kogen-build        | Kogen's implementation workflow: `kogen intent build`, `resume` and `recover`.                         | [KogenAI/kogen-build](https://github.com/KogenAI/kogen-build)               |
      | kogen-review       | Kogen's independent review and repair of a Build's verified candidate.                                 | [KogenAI/kogen-review](https://github.com/KogenAI/kogen-review)             |
      | kogen-verification | Kogen's deterministic verification: running checks, scenarios and models, and recording the evidence.  | [KogenAI/kogen-verification](https://github.com/KogenAI/kogen-verification) |
      | kogen-executor     | Kogen's shared execution and session contracts and its backend adapters.                               | [KogenAI/kogen-executor](https://github.com/KogenAI/kogen-executor)         |
      | kogen-loop         | Standalone Go agent-loop library and CLI, using only the standard library.                             | [KogenAI/kogen-loop](https://github.com/KogenAI/kogen-loop)                 |
      | kogen-setup        | Kogen's setup: `kogen init` configures an existing project for Kogen.                                  | [KogenAI/kogen-setup](https://github.com/KogenAI/kogen-setup)               |

  Scenario: Every section removed from the README is verbatim in a docs file linked from "More"
    Given k-readme-lineup: the repository README
    Then k-readme-lineup: every one of these original README sections is in a docs file linked from the More list:
      | heading                                          | sha256                                                           |
      | Overview                                         | 40a89f1c9117366ffc958b07d4b66b53bdc5042ddb2b279c63a813d43482705b |
      | Status                                           | 507286af9b5ae162c5549956476791bd1cbb351e4429e819d6677d7edaa3225a |
      | Getting started                                  | 9751821cd75bc630d7957e8a034e3a40d6072e22959f089829cc7bac49e6ff95 |
      | Specification                                    | 7dfa9d4c19763ea20831f6556ea63c0db587dd38cfdbb2f661bf2db1cd27e5c3 |
      | Development                                      | 271b844411ae27ed66ad12bc5fa8e53282e179ed84ec03f095a47b240832bb05 |
      | Folder map                                       | 5f52af073e9d07a062aae24f9004167bb6527ea9a84e0fd554e98bc310576c94 |
      | Contact                                          | 8fc09328df5627ce8b8c14c33e466af8300e4ad67fe45931a57e2c73dfb5b82f |
      | License                                          | 29e2d9e6051e286588dde7af8235f9ee769ecd41a632ca11daf277347279d841 |
      | Clean final readiness                            | e7d7b6ca144df660465ce655ce2990842be41c90578401af0404092b4b2b1d75 |
      | Checkout facts and completion                    | eda8ea62987e5bf66796f234a2f471cd6a61d7e2e4c1bda3370009a76997c7b4 |
      | Prompt reuse and retained usage                  | 0e36c93453a9cf4366a6d014a0ed80ff2f7d38d5cb328339d7937b3d85b77cf0 |
      | Private working continuity and source provenance | 67402e823306bd6a1bd83e126698e45b36a24410ed5c62b6ceec10d6df26a665 |
      | Selected native image evidence                   | 01f0f9c766c68f051f8850640731c6d05f1220271d1ec28dbd1f8396d1fcf1bb |
      | Approval step limits and refusal diagnostics     | f53bf6074349c39db7c2e563de30e8d5016dc96035305466446e7e81e50acb4d |
      | Recovering stale approval cards                  | d93568d291d864b23144a6c527654585c609a7a26ccf50aff891dea89e939c10 |

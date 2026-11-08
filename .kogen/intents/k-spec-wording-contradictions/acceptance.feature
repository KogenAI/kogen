Feature: Correct published wording without behavior changes

  Scenario Outline: k-spec-wording-contradictions: Published passages state current rules
    Then k-spec-wording-contradictions: file "<path>" contains "<text>"

    Examples:
      | path | text |
      | spec/prose/05-verifying.md | the whole output when it has at most 60 lines, else the first 30 and the last 20 |
      | spec/prose/04-building.md | and `KOGEN_CUCUMBER` |
      | spec/prose/04-building.md | `KOGEN_QUINT` |
      | spec/prose/04-building.md | three acceptance variables |
      | spec/prose/09-cli-and-process.md | Command names, grammar, exit codes and the error-line format are fixed for the commands this version has. |
      | spec/prose/08-chatgpt.md | `kogen provider list` prints |
      | spec/prose/09-cli-and-process.md | On SIGINT, SIGTERM or SIGHUP |
      | spec/prose/09-cli-and-process.md | Each project command |
      | docs/testing-strategy.md | as `test/acceptance/support/fake-servers.js` does. |
      | README.md | Run these in your own Git repository (a Build needs a clean working tree, so keep the request file outside the repository, or commit it): |
      | packaging/README.md | Run these commands in a Git repository with at least one commit (a Build needs a clean working tree, so keep the request file outside the repository, or commit it): |

  Scenario Outline: k-spec-wording-contradictions: Remove obsolete phrasing at cited documents
    Then k-spec-wording-contradictions: file "<path>" excludes "<text>"

    Examples:
      | path | text |
      | spec/prose/05-verifying.md | at most 60 lines: the first 30 and the last 20 |
      | spec/prose/04-building.md | the two acceptance variables |
      | spec/prose/09-cli-and-process.md | the agreed CLI |
      | spec/prose/08-chatgpt.md | the agreed provider status command |
      | spec/prose/09-cli-and-process.md | every build before the Initial commit |
      | spec/prose/09-cli-and-process.md | SIGINT history |
      | docs/testing-strategy.md | does today |

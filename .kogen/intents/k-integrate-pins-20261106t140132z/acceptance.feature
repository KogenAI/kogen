Feature: kogen's qualification is green on the new component tuple, with model roles only in the models files
  The base is the pin commit db9a3b229573 with every component at its newest main:
  kogen-loop c2f529be5aa1 -> 3505e6023bdb, kogen-coordinator c8126f4156ba -> e91a9e0ac65b,
  kogen-verification a83b8096ecdb -> e1ff81b79447, kogen-shaping 88a929ea41ee -> 0484edf817f6,
  kogen-build fdbef3d41add -> 88b77ba3dbf3, kogen-executor c7382270875a -> 55b372c4dd31,
  kogen-setup 9630cce549f9 -> c0afc56136fe, kogen-review 22dc61ec5953 -> cdcbbe3e357a.
  Model roles live only in .kogen/models.yaml and the host-local .kogen/local/models.yaml
  (defaults < models.yaml < local); .kogen/project.yaml refuses a models key.

  Scenario: The adoption's Go reds pass with the pins unchanged
    Then k-integrate-pins-20261106t140132z: the cli module resolves the components:
      | module                                | version                                    |
      | github.com/KogenAI/kogen-loop         | v0.0.0 => ./third_party/kogen-loop         |
      | github.com/KogenAI/kogen-coordinator  | v0.0.0-20261106121202-e91a9e0ac65b         |
      | github.com/KogenAI/kogen-verification | v0.0.0-20261106121212-e1ff81b79447         |
      | github.com/KogenAI/kogen-shaping      | v0.0.0-20261106124640-0484edf817f6         |
      | github.com/KogenAI/kogen-build        | v0.0.0-20261106130303-88b77ba3dbf3         |
      | github.com/KogenAI/kogen-executor     | v0.0.0-20261106121702-55b372c4dd31         |
      | github.com/KogenAI/kogen-setup        | v0.0.0-20261106122420-c0afc56136fe         |
      | github.com/KogenAI/kogen-review       | v0.0.0-20261106124750-cdcbbe3e357a         |
    And k-integrate-pins-20261106t140132z: the loop pin names module "github.com/KogenAI/kogen-loop" at source head "3505e6023bdbfae6a62287b666def948fec75f80"
    And k-integrate-pins-20261106t140132z: gofmt lists no file in cli
    And k-integrate-pins-20261106t140132z: "go build ./..." in "cli" succeeds
    And k-integrate-pins-20261106t140132z: "go vet ./..." in "cli" succeeds
    And k-integrate-pins-20261106t140132z: these Go tests pass in one run:
      | test                                               | package                      |
      | TestExternalIsTheExecutorFactoryOfBuildRoles       | ./consumes/kogen-build       |
      | TestRoleProviderAndExecutor                        | ./consumes/kogen-coordinator |
      | TestReadableConfigKeepsWhatItCanRead               | ./consumes/kogen-coordinator |
      | TestRefineAsksKogensExecutorForAnExternalShapeRole | ./consumes/kogen-shaping     |
      | TestShapeAsksKogensExecutorForAnExternalShapeRole  | ./consumes/kogen-shaping     |
      | TestModelsChecks                                   | ./readiness                  |
      | TestUsageLimitResumeInstalledRound2                | .                            |
      | TestUsageLimitResumeInstalledRound3                | .                            |
      | TestUsageLimitPackagingIsolationRound2             | .                            |
      | TestUsageLimitPackagingIsolationRound3             | .                            |

  Scenario: A fresh home with only a claude-code login installs, inits, shapes, approves and builds a feature that lands, with no ChatGPT hint
    Given k-integrate-pins-20261106t140132z: the release built from this checkout is installed in a fresh home
    When k-integrate-pins-20261106t140132z: a claude-code login alone inits, shapes, approves and builds a feature that lands
    Then k-integrate-pins-20261106t140132z: kogen init printed the line "ok models - shape, build, review ready"
    And k-integrate-pins-20261106t140132z: no output and no lineup file mentions ChatGPT

  Scenario: Each lineup preset is a team models file that readiness reads from .kogen/models.yaml
    Given k-integrate-pins-20261106t140132z: the release built from this checkout is installed in a fresh home
    Then k-integrate-pins-20261106t140132z: kogen init in an initialized project whose team models file is each preset prints its models and fix lines:
      | preset                     | models line                                                                                                                           | fix line after two spaces                                                                           |
      | anthropic-only.yaml        | fail models - shape: anthropic has no stored login; build: anthropic has no stored login; review: anthropic has no stored login       | fix: kogen provider login anthropic                                                                 |
      | opencode-go-only.yaml      | fail models - shape: opencode-go has no stored login; build: opencode-go has no stored login; review: opencode-go has no stored login | fix: kogen provider login opencode-go                                                               |
      | supergrok-only.yaml        | fail models - shape: supergrok has no stored login; build: supergrok has no stored login; review: supergrok has no stored login       | fix: kogen provider login supergrok                                                                 |
      | supergrok-opencode-go.yaml | fail models - shape: supergrok has no stored login; build: opencode-go has no stored login; review: supergrok has no stored login     | fix: kogen provider login supergrok; kogen provider login opencode-go                               |
      | three-subscriptions.yaml   | fail models - shape: chatgpt has no stored login; build: opencode-go has no stored login; review: supergrok has no stored login       | fix: kogen provider login chatgpt; kogen provider login opencode-go; kogen provider login supergrok |

  Scenario: Readiness's models line takes each role from the host-local lineup over the team lineup
    Given k-integrate-pins-20261106t140132z: the release built from this checkout is installed in a fresh home
    And k-integrate-pins-20261106t140132z: an initialized project with these files:
      """
      === .kogen/models.yaml
      models:
        shape: {provider: supergrok, model: grok-4.7, effort: high}
        build: {provider: supergrok, model: grok-4.7, effort: medium}
        review: {provider: supergrok, model: grok-4.7, effort: high}
      === .kogen/local/models.yaml
      models:
        build: {provider: opencode-go, model: kimi-k3, effort: high}
      """
    When k-integrate-pins-20261106t140132z: kogen init runs in the project
    Then k-integrate-pins-20261106t140132z: kogen init exits 0 and prints the lines:
      """
      ok config - .kogen/project.yaml is valid
      fail models - shape: supergrok has no stored login; build: opencode-go has no stored login; review: supergrok has no stored login
        fix: kogen provider login supergrok; kogen provider login opencode-go
      """

  Scenario: No documentation example of .kogen/project.yaml carries a models key
    Then k-integrate-pins-20261106t140132z: no fenced example in README.md, docs or the spec prose sets both version 1 and a root models key

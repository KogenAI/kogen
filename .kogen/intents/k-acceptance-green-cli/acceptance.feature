Feature: Packaged CLI agrees with its maintained scenarios
  Scenario: Qualify the nine repaired cases and preserve the non-live baseline
    When I run the CLI repair selections three times and the non-live suite once:
      | file                                 | original_line | name                                                                                  | command                                                                |
      | 01-project-setup.feature             | 9             | Init configures a project without checks or runner, adds the bridge and commits once    |                                                                        |
      | 01-project-setup.feature             | 37            | Init configures an Elixir project and leaves out a check that fails on the committed tree |                                                                      |
      | 01-project-setup.feature             | 61            | Init configures a Node project with its existing runner and a check the model found      |                                                                        |
      | 01-project-setup.feature             | 140           | In a repository without commits, init makes the first commit                            |                                                                        |
      | 01-project-setup.feature             | 305           | An executor on the review role is a configuration error                                  |                                                                        |
      | 07-committing.feature                | 14            | A verified, approved Build makes one commit                                             |                                                                        |
      | 09-cli-and-process.feature           | 115           | Usage errors print the message, a blank line and the page meant                          | kogen provider login grok                                               |
      | 09-cli-and-process.feature           | 116           | Usage errors print the message, a blank line and the page meant                          | kogen provider login openai-compatible --base-url https://a.example/v1    |
      | 10-install-and-uninstall.feature     | 63            | An unsupported platform is refused                                                      |                                                                        |
    Then all 9 selected scenarios passed on each run and the 266 scenario suite has no regression outside:
      | 02-shaping.feature:22  |
      | 02-shaping.feature:379 |
      | 02-shaping.feature:380 |
      | 02-shaping.feature:395 |
      | 02-shaping.feature:423 |
      | 06-reviewing.feature:33 |
      | 06-reviewing.feature:44 |

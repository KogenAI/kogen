Feature: ChatGPT connection
  Kogen's own login, its status, refresh, streaming and precise provider errors.

  Background:
    Given a clean Kogen home
    And the installed kogen command
    And the fake ChatGPT authorization server is running

  @GPT-2 @GPT-3 @GPT-4
  Scenario: Browser login, private credentials and the status command
    When the caller runs "kogen provider list"
    Then stdout is:
      """
      chatgpt: not signed in
      """
    When the caller runs "kogen provider login chatgpt" in the background
    And the browser completes sign-in for "user@example.com"
    And the background command finishes
    Then the exit code is 0
    And stdout is:
      """
      Continue with ChatGPT
      {url}
      chatgpt signed in (user@example.com)
      """
    And the authorization request used PKCE S256 and a fresh state
    And the file "{home}/.kogen/credentials/chatgpt.json" has mode "600"
    When the caller runs "kogen provider list"
    Then stdout is:
      """
      chatgpt: signed in (user@example.com)
      """

  @GPT-4
  Scenario: An incomplete saved login is not reported as signed in
    Given the file "{home}/.kogen/credentials/chatgpt.json" contains:
      """
      {"client_id":"oaiapp_test","refresh_token":"refresh-token","email":"user@example.com"}
      """
    When the caller runs "kogen provider list"
    Then the exit code is 0
    And stdout is:
      """
      chatgpt: saved login cannot be used; run kogen provider login chatgpt
      """

  @GPT-2
  Scenario: A redirect with the wrong state is ignored and the right one succeeds
    When the caller runs "kogen provider login chatgpt" in the background
    And the browser sends a redirect with the wrong state
    Then the kogen command is still running
    And the file "{home}/.kogen/credentials/chatgpt.json" does not exist
    When the browser completes sign-in for "user@example.com"
    And the background command finishes
    Then the exit code is 0
    And stdout contains "chatgpt signed in (user@example.com)"

  @GPT-2
  Scenario: A login without plan usage granted keeps nothing
    Given the fake authorization server grants only "openid profile email offline_access"
    When the caller runs "kogen provider login chatgpt" in the background
    And the browser completes sign-in for "user@example.com"
    And the background command finishes
    Then the exit code is 4
    And stdout contains "provider/login_failed: ChatGPT plan usage was not granted; sign in again and allow it"
    And the file "{home}/.kogen/credentials/chatgpt.json" does not exist

  @GPT-2
  Scenario: Login by pasting the redirect URL on a machine whose browser is elsewhere
    When the caller runs "kogen provider login chatgpt" with the sign-in redirect URL on stdin
    Then the exit code is 0
    And stdout contains "chatgpt signed in"

  @GPT-1 @GPT-5
  Scenario: Without Kogen's own login nothing is sent, and Codex credentials are never used
    Given a Git project from fixture "py-calc"
    And the project is initialized and configured
    And the file "{home}/.codex/auth.json" holds a ChatGPT token "CODEX-TOKEN"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n).
      """
    Then the exit code is 4
    And stdout is:
      """
      provider/login: not signed in; run kogen provider login chatgpt
      """
    And the fake ChatGPT server received 0 requests

  @GPT-4 @GPT-5
  Scenario: An incomplete saved login is refused before any model request
    Given a Git project from fixture "py-calc"
    And the project is initialized and configured
    And the file "{home}/.kogen/credentials/chatgpt.json" contains:
      """
      {"client_id":"oaiapp_test","refresh_token":"refresh-token"}
      """
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n).
      """
    Then the exit code is 4
    And stdout is:
      """
      provider/login: saved login cannot be used; run kogen provider login chatgpt
      """
    And the fake ChatGPT server received 0 requests

  @GPT-6
  Scenario: An expired access token is refreshed and the rotated refresh token is saved
    Given a Git project from fixture "py-calc"
    And the project is initialized and configured
    And the caller is signed in to ChatGPT with an expired access token
    And the fake ChatGPT server plays script "shape-ready-is-even"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n).
      """
    Then the exit code is 0
    And the authorization server received 1 refresh request
    And the saved refresh token is the rotated one

  @GPT-3 @GPT-6
  Scenario: Two commands that start at once with an expired access token refresh it once
    Given a Git project from fixture "py-calc" in the folder "a"
    And the project is initialized and configured
    And a Git project from fixture "py-calc" in the folder "b"
    And the project is initialized and configured
    And the caller is signed in to ChatGPT with an expired access token
    And the fake ChatGPT server plays script "shape-ready-is-even"
    When the caller runs "kogen intent shape is-even - --project a" and "kogen intent shape is-even - --project b" at the same time with stdin:
      """
      Add calc.is_even(n).
      """
    Then both commands exit 0
    And the authorization server received 1 refresh request
    And the saved refresh token is the rotated one

  @GPT-6
  Scenario: A rejected access token and refresh token ask for a new login
    Given a Git project from fixture "py-calc"
    And the project is initialized and configured
    And the caller is signed in to ChatGPT
    And the fake ChatGPT server plays script "401-then-ok"
    And the authorization server rejects refresh
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n).
      """
    Then the exit code is 4
    And stdout contains "provider/login: the ChatGPT sign-in was rejected; run kogen provider login chatgpt"

  @GPT-7 @GPT-8
  Scenario Outline: Provider errors are classified with bounded retries
    Given a Git project from fixture "py-calc"
    And the project is initialized and configured
    And the caller is signed in to ChatGPT
    And the fake ChatGPT server plays script "<script>"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n).
      """
    Then the exit code is <exit>
    And stdout contains "<line>"
    And the fake ChatGPT server received <requests> requests

    # Successful red shaping uses two HTTP attempts plus one observation acknowledgment.
    Examples:
      | script             | exit | line                                                                             | requests |
      | 500-always         | 4    | provider/unavailable: ChatGPT did not answer after 3 attempts                   | 3        |
      | stream-cut-then-ok | 0    | Next: kogen intent approve is-even                                               | 3        |
      | 401-then-ok        | 0    | Next: kogen intent approve is-even                                               | 3        |
      | model-unavailable  | 4    | provider/model_unavailable: gpt-6.1-sol is not available to this ChatGPT account | 1        |
      | 400-bad-request    | 4    | provider/refused: ChatGPT refused the request: 400                               | 1        |

  @GPT-8 @GIT-8
  Scenario: A provider outage during a Build ends it without a commit
    Given a Git project from fixture "py-calc"
    And the project is initialized and configured
    And the caller is signed in to ChatGPT
    And the Intent "is-even" from fixture "is-even" is approved
    And the fake ChatGPT server plays script "build-then-500-always"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 4
    And stdout contains "provider/unavailable: "
    And HEAD is unchanged
    And every tool call in the run log ran once

  @GPT-9 @GPT-10
  Scenario: Usage is printed and tokens never leak
    Given a Git project from fixture "py-calc"
    And the project is initialized and configured
    And the caller is signed in to ChatGPT
    And the fake ChatGPT server plays script "shape-ready-is-even"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n).
      """
    Then stdout contains "input="
    And neither stdout nor stderr contains the fake access token
    And no Kogen process had the fake access token in its arguments or environment
    And no file under "." contains the fake access token

  @GPT-11
  Scenario: Test seams accept only loopback URLs
    Given the environment variable "KOGEN_AUTH_URL" is "https://example.com"
    When the caller runs "kogen provider login chatgpt"
    Then the exit code is 3
    And stdout is:
      """
      environment/invalid_test_seam: KOGEN_AUTH_URL must be http://127.0.0.1:<port> or http://localhost:<port>
      """

  @GPT-7 @GPT-8 @GIT-8
  Scenario Outline: Invalid terminal tools cannot edit the candidate
    Given a Git project from fixture "py-calc"
    And the project is initialized and configured
    And the caller is signed in to ChatGPT
    And the Intent "is-even" from fixture "is-even" is approved
    And the fake ChatGPT server plays script "<script>"
    When the caller runs "kogen intent build is-even"
    Then the exit code is 4
    And stdout contains "provider/invalid_response"
    And stdout contains "; validation="
    And stdout contains "<predicate>"
    And the fake ChatGPT server received 2 requests
    And the file "unauthorized.txt" does not exist
    And HEAD is unchanged

    Examples:
      | script          | predicate     |
      | unfinished-tool | pending_items |
      | malformed-tool  | item_shape    |
      | unfinished-tool-empty-final | pending_items |
      | malformed-tool-empty-final | item_shape |

  @GPT-7 @GPT-8
  Scenario: Empty final metadata preserves complete streamed tools
    Given a Git project from fixture "py-calc"
    And the project is initialized and configured
    And the caller is signed in to ChatGPT
    And the fake ChatGPT server plays script "shape-asks-one-empty-final"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n).
      """
    Then the exit code is 5
    And stdout contains "1. What should is_even do with a non-integer?"
    And the fake ChatGPT server received 1 requests
    And the file ".kogen/intents/is-even/intent.md" does not exist
    And HEAD is unchanged

  @GPT-9
  Scenario: Empty local retained usage is honest and requires no provider
    Given a Git project from fixture "py-calc"
    And the project is initialized and configured
    When the caller runs "kogen intent usage --json"
    Then the exit code is 0
    And stdout contains "usage"

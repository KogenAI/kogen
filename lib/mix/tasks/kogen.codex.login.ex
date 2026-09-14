defmodule Mix.Tasks.Kogen.Codex.Login do
  @moduledoc """
  Logs into the managed native Codex runtime for the selected Kogen credential scope.

  With no options, native Codex starts its default browser login:

      mix kogen.codex.login

  Put Kogen's optional scope selector before `--`; everything after `--` is
  passed unchanged to native `codex login`. For example, use native device
  authentication in the shared scope or in this project's private scope:

      mix kogen.codex.login -- --device-auth
      mix kogen.codex.login --project -- --device-auth

  Device authentication is native ChatGPT authentication and needs a human to
  authorize it. To supply an API key through native stdin for unattended
  credential provisioning, use:

      printenv OPENAI_API_KEY | mix kogen.codex.login -- --with-api-key
      printenv OPENAI_API_KEY | mix kogen.codex.login --project -- --with-api-key

  Ask the installed native Codex for its available login options with:

      mix kogen.codex.login -- --help
      mix kogen.codex.login --project -- --help

  This help is available before installing a managed runtime or logging in, and
  does not start login. Kogen delegates authentication methods, terminal
  interaction, credential persistence, and refresh to native Codex.
  """
  use Mix.Task
  use Boundary, deps: [Kogen.Codex.CLI, Mix]
  alias Kogen.Codex.CLI
  @shortdoc "Delegates native login to the selected Kogen credential scope"
  @impl Mix.Task
  def run(args), do: CLI.run(:login, args)
end

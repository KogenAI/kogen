defmodule Kogen.ClaudeCode.CLI do
  @moduledoc false
  use Boundary, top_level?: true, deps: [Kogen.ClaudeCode, Kogen.Intent]

  def run(command, args) do
    case dispatch(command, args) do
      :ok ->
        :ok

      {:error, reason} ->
        IO.puts(:stderr, if(is_binary(reason), do: reason, else: inspect(reason)))
        System.halt(1)
    end
  rescue
    error ->
      IO.puts(:stderr, Exception.message(error))
      System.halt(1)
  end

  defp dispatch(:install, []) do
    with {:ok, runtime} <- Kogen.ClaudeCode.install() do
      IO.puts(
        "Kogen Claude Code #{runtime["version"]} installed and validated: #{runtime["path"]}"
      )

      installation_readiness()
      :ok
    end
  end

  defp dispatch(:login, args) do
    with {:ok, config} <- Kogen.Intent.read_config(),
         {:ok, status} <- Kogen.ClaudeCode.login(args, config) do
      if status == 0, do: :ok, else: System.halt(status)
    end
  end

  defp dispatch(:status, []) do
    with {:ok, config} <- Kogen.Intent.read_config(),
         {:ok, status} <- Kogen.ClaudeCode.status(config) do
      IO.puts("Pinned Claude Code: #{status.pin}")

      if status.runtime do
        IO.puts("Installed: #{status.runtime["version"]} (#{status.runtime["path"]})")
      else
        IO.puts("Not installed. Run mix kogen.claude.install")
      end

      IO.puts("Effective login: #{status.scope.name} (#{status.scope.path})")
      IO.puts("Local login state: #{format_login(status.login)}")
      IO.puts("Local login state does not establish model access or remaining allowance.")
      :ok
    end
  end

  defp dispatch(command, _args), do: {:error, "usage: mix kogen.claude.#{command}"}

  defp installation_readiness do
    with {:ok, config} <- Kogen.Intent.read_config(),
         {:ok, status} <- Kogen.ClaudeCode.status(config) do
      print_readiness(status)
    else
      _ -> IO.puts("Run mix kogen.claude.status from a configured Kogen checkout.")
    end
  end

  defp print_readiness(%{login: {:configured, _metadata}}),
    do: IO.puts("Selected Kogen Claude Code login is configured.")

  defp print_readiness(%{login: :missing, scope: scope}) do
    suffix = if scope.name == :project, do: " --project", else: ""
    IO.puts("Run mix kogen.claude.login#{suffix} to configure the selected Kogen login.")
  end

  defp print_readiness(_status),
    do: IO.puts("Run mix kogen.claude.status to inspect local login readiness.")

  defp format_login({:configured, metadata}),
    do: "logged in (loggedIn: true, authMethod: #{metadata.auth_method})"

  defp format_login(:missing), do: "not logged in (loggedIn: false)"
  defp format_login(:unavailable), do: "unavailable until installation"
  defp format_login({:error, reason}), do: "failed: #{reason}"
end

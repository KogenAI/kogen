defmodule Kogen.Codex.CLI do
  @moduledoc false
  use Boundary, top_level?: true, deps: [Kogen.Codex, Kogen.Intent]

  def run(command, args) do
    result = dispatch(command, args)

    case result do
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
    with {:ok, runtime} <- Kogen.Codex.install() do
      IO.puts("Kogen Codex #{runtime["version"]} installed and validated: #{runtime["path"]}")

      installation_readiness()
      :ok
    end
  end

  defp dispatch(:login, args) do
    with {:ok, config} <- Kogen.Intent.read_config(),
         {:ok, status} <- Kogen.Codex.login(args, config) do
      if status == 0, do: :ok, else: System.halt(status)
    end
  end

  defp dispatch(:status, []) do
    with {:ok, config} <- Kogen.Intent.read_config(),
         {:ok, status} <- Kogen.Codex.status(config) do
      if status.runtime do
        IO.puts("Default: #{status.runtime["version"]} (#{status.runtime["path"]})")
      else
        IO.puts("No managed runtime. Run mix kogen.codex.install")
      end

      IO.puts("Effective login: #{status.scope.name} (#{status.scope.path})")
      IO.puts("Native local login state: #{format_login(status.login)}")
      IO.puts("Local login state does not establish model access or remaining allowance.")

      for active <- status.active do
        IO.puts(
          "Active: #{active["runtime"]["version"]} in #{active["project"]} (PID #{active["pid"]})"
        )
      end

      if status.active == [], do: IO.puts("No active Kogen operations.")
      :ok
    end
  end

  defp dispatch(command, _args), do: {:error, "usage: mix kogen.codex.#{command}"}

  defp installation_readiness do
    with {:ok, config} <- Kogen.Intent.read_config(),
         {:ok, status} <- Kogen.Codex.status(config) do
      print_readiness(status)
    else
      _ -> IO.puts("Run mix kogen.codex.status from a configured Kogen checkout.")
    end
  end

  defp print_readiness(%{login: :configured}), do: IO.puts("Selected Kogen login is configured.")

  defp print_readiness(%{login: :missing, scope: scope}) do
    suffix = if scope.name == :project, do: " --project", else: ""
    IO.puts("Run mix kogen.codex.login#{suffix} to configure the selected Kogen login.")
  end

  defp print_readiness(_),
    do: IO.puts("Run mix kogen.codex.status to inspect local login readiness.")

  defp format_login(:configured), do: "configured"
  defp format_login(:missing), do: "not configured"
  defp format_login(:unavailable), do: "unavailable until installation"
  defp format_login({:error, reason}), do: "failed: #{reason}"
end

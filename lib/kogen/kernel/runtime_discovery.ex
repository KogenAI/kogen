defmodule Kogen.Kernel.RuntimeDiscovery do
  @moduledoc false

  alias Kogen.Contracts.ProviderError
  alias Kogen.Engine.Runtime
  alias Kogen.Provider.ChatGPT

  @spec runtime() ::
          {:ok, Runtime.t()}
          | {:error,
             :mise_missing | :too_many_script_symlinks | {:script_path_unavailable, term()}}
  def runtime do
    system_env = System.get_env()
    mise = System.find_executable("mise")
    ert = runtime_path(:erts)
    bindir = runtime_path(:bindir)

    case mise do
      nil -> {:error, :mise_missing}
      path -> runtime_with_script(system_env, path, ert, bindir)
    end
  end

  @spec home() :: {:ok, Path.t()} | {:error, :home_unavailable}
  def home do
    case System.get_env("HOME") do
      home when is_binary(home) and home != "" ->
        {:ok, Path.expand(home)}

      _missing ->
        case System.user_home() do
          home when is_binary(home) and home != "" -> {:ok, Path.expand(home)}
          _missing -> {:error, :home_unavailable}
        end
    end
  end

  @spec resolve_script_path(Path.t() | nil) :: {:ok, Path.t() | nil} | {:error, term()}
  def resolve_script_path(nil), do: {:ok, nil}

  def resolve_script_path(path) when is_binary(path) do
    resolve_script_link(Path.expand(path), 0)
  end

  @spec provider_config() ::
          {:ok, ChatGPT.Config.t(), :kogen_owned | :codex_borrowed | :custom}
          | {
              :error,
              ProviderError.t()
            }
  def provider_config do
    home = System.get_env("HOME") || ""
    explicit = System.get_env("KOGEN_AUTH_PATH")
    {path, source} = credential_path(explicit, home)

    with {:ok, config} <- ChatGPT.config(path) do
      {:ok, config, source}
    end
  end

  defp runtime_with_script(system_env, mise, ert, bindir) do
    with {:ok, script} <- resolve_script_path(escript_path()) do
      {:ok, Runtime.new(system_env, mise, script, ert, bindir)}
    end
  end

  defp credential_path(path, _home) when is_binary(path) and path != "",
    do: {Path.expand(path), :custom}

  defp credential_path(_path, home) do
    kogen = Path.join([home, ".kogen", "auth.json"])
    codex = Path.join([home, ".codex", "auth.json"])

    cond do
      File.regular?(kogen) -> {kogen, :kogen_owned}
      File.regular?(codex) -> {codex, :codex_borrowed}
      true -> {codex, :codex_borrowed}
    end
  end

  defp escript_path do
    case :escript.script_name() do
      [] ->
        nil

      name ->
        path = List.to_string(name)
        if File.regular?(path), do: path
    end
  end

  defp resolve_script_link(_path, depth) when depth >= 40, do: {:error, :too_many_script_symlinks}

  defp resolve_script_link(path, depth) do
    case File.read_link(path) do
      {:ok, target} -> resolve_script_link(Path.expand(target, Path.dirname(path)), depth + 1)
      {:error, :einval} -> {:ok, path}
      {:error, reason} -> {:error, {:script_path_unavailable, reason}}
    end
  end

  defp runtime_path(:erts), do: :erts |> :code.lib_dir() |> List.to_string()

  defp runtime_path(:bindir) do
    :code.root_dir() |> List.to_string() |> Path.join("bin")
  end
end

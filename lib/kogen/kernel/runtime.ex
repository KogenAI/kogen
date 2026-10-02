defmodule Kogen.Kernel.Runtime do
  @moduledoc false

  @enforce_keys [:base_env, :git_env, :mise]
  defstruct [:base_env, :git_env, :mise]

  @type t :: %__MODULE__{
          base_env: %{String.t() => String.t()},
          git_env: %{String.t() => String.t()},
          mise: Path.t()
        }

  @base_keys ~w(PATH HOME LANG LC_ALL TERM TMPDIR USER SHELL MIX_HOME HEX_HOME)

  @spec new(map(), Path.t(), Path.t() | nil, Path.t(), Path.t()) :: t()
  def new(system_env, mise, script_path, ert_dir, ert_bin) do
    env = selected_environment(system_env)
    markers = runtime_markers(script_path, ert_dir, ert_bin)
    base_env = Map.merge(env, markers)

    %__MODULE__{
      base_env: base_env,
      git_env: git_environment(base_env),
      mise: mise
    }
  end

  @spec process_env(t(), map()) :: %{String.t() => String.t()}
  def process_env(%__MODULE__{} = runtime, toolchain_env) do
    runtime.base_env
    |> Map.merge(toolchain_env)
    |> include_mise_binary(runtime.mise)
    |> Map.merge(runtime_markers_from(runtime.base_env))
  end

  @spec git_environment(map()) :: %{String.t() => String.t()}
  def git_environment(env) when is_map(env) do
    Map.filter(env, fn {key, _value} ->
      key in @base_keys or String.starts_with?(key, ["GIT_", "MISE_", "KOGEN_"])
    end)
  end

  @spec for_project(t(), map()) :: t()
  def for_project(%__MODULE__{} = runtime, process_env) when is_map(process_env) do
    %{runtime | git_env: git_environment(process_env)}
  end

  defp selected_environment(system_env) do
    Map.filter(system_env, fn {key, _value} ->
      key in @base_keys or String.starts_with?(key, ["GIT_", "MISE_"])
    end)
  end

  defp include_mise_binary(env, mise) do
    mise_dir = Path.dirname(mise)
    entries = env |> path_value() |> String.split(":", trim: true)
    path = Enum.join(Enum.uniq([mise_dir | entries]), ":")
    Map.merge(env, Map.new([{"PATH", path}]))
  end

  defp path_value(env) do
    Enum.find_value(env, "", fn
      {"PATH", path} -> path
      _other -> nil
    end)
  end

  defp runtime_markers(script_path, ert_dir, ert_bin) do
    [{"KOGEN_ERTS_DIR", ert_dir}, {"KOGEN_ERTS_BIN", ert_bin}]
    |> maybe_escript_marker(script_path)
    |> Map.new()
  end

  defp maybe_escript_marker(markers, nil), do: markers

  defp maybe_escript_marker(markers, script_path),
    do: markers ++ [{"KOGEN_ESCRIPT_DIR", Path.dirname(script_path)}]

  defp runtime_markers_from(env) do
    Map.take(env, ["KOGEN_ERTS_DIR", "KOGEN_ERTS_BIN", "KOGEN_ESCRIPT_DIR", "KOGEN_BIN_DIR"])
  end
end

defmodule Kogen.Kernel.Environment do
  @moduledoc false

  alias Kogen.Contracts.ProcResult
  alias Kogen.Kernel.Runtime
  alias Kogen.Proc

  @spec project(Path.t(), Runtime.t()) ::
          {:ok, %{String.t() => String.t()}}
          | {:error, :toolchain_failed | :invalid_toolchain_environment}
  def project(workdir, %Runtime{} = runtime) do
    case Proc.run(
           [runtime.mise, "env", "-C", workdir, "--json"],
           cd: workdir,
           env: runtime.base_env,
           timeout_ms: 30_000
         ) do
      {:ok, %ProcResult{exit_status: 0, timed_out: false, output_tail: output}} ->
        decode_environment(output, runtime)

      {:ok, %ProcResult{}} ->
        {:error, :toolchain_failed}

      {:error, _reason} ->
        {:error, :toolchain_failed}
    end
  end

  defp decode_environment(output, runtime) do
    case :json.decode(output) do
      values when is_map(values) ->
        with {:ok, env} <- string_environment(values) do
          {:ok, Runtime.process_env(runtime, env)}
        end

      _other ->
        {:error, :invalid_toolchain_environment}
    end
  rescue
    ArgumentError -> {:error, :invalid_toolchain_environment}
  end

  defp string_environment(values) do
    Enum.reduce_while(values, {:ok, %{}}, fn {key, value}, {:ok, env} ->
      if is_binary(key) and is_binary(value) do
        {:cont, {:ok, Map.put(env, key, value)}}
      else
        {:halt, {:error, :invalid_toolchain_environment}}
      end
    end)
  end
end

defmodule Kogen.Kernel.RuntimeDiscovery do
  @moduledoc false

  alias Kogen.Contracts.ProviderError
  alias Kogen.Kernel.Runtime
  alias Kogen.Provider.ChatGPT

  @spec runtime() :: {:ok, Runtime.t()} | {:error, :mise_missing}
  def runtime do
    system_env = System.get_env()
    mise = System.find_executable("mise")
    script = escript_path()
    ert = runtime_path(:erts)
    bindir = runtime_path(:bindir)

    case mise do
      nil -> {:error, :mise_missing}
      path -> {:ok, Runtime.new(system_env, path, script, ert, bindir)}
    end
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
      [] -> nil
      name -> List.to_string(name)
    end
  end

  defp runtime_path(:erts), do: :erts |> :code.lib_dir() |> List.to_string()

  defp runtime_path(:bindir) do
    :code.root_dir() |> List.to_string() |> Path.join("bin")
  end
end

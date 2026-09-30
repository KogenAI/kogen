defmodule Kogen.Codex.AccountObservation do
  @moduledoc """
  Produces fresh native account/remote plugin observations for one effective
  Codex launch context, the evidence `Kogen.Codex.AccountPlugins` judges.

  Two bounded, read-only `codex app-server` sessions run through
  `priv/kogen/codex/compatibility/account_observation.py` (no model turn, no
  tool call, own process group, secrets dropped), on the pinned executable,
  the selected scope (`CODEX_HOME`), the same environment and working
  directory. The driver runs Codex in a disposable home holding copies of the
  scope's `auth.json` and `config.toml`, so the shared scope is only read and
  never gains a `plugins/` tree; the reported home is mapped back to the scope:

    * `scope-off`: exactly the production launch arguments, which disable
      apps and plugins;
    * `scope-on`: the positive control, the same arguments with only those
      two flags switched to `--enable`.

  Each receipt binds what was actually observed: runtime version, executable
  digest, the server-reported `codexHome`, the account fingerprint, the
  effective arguments (`args_sha256`) and the launch binding shared by both
  sessions (arguments without the apps/plugins flags, scope home, cwd).
  Counts come from native `app/installed` and `plugin/installed`; discovery
  from `app/list` as returned (a timeout or error is recorded as such). A
  failed or missing session yields a receipt with its error and no counts,
  never an invented empty list.
  """

  use Boundary, top_level?: true, deps: []

  @flags ["apps", "plugins"]

  @doc """
  Observes both sessions and writes one receipt per mode into `dir`.
  `context` is the effective launch context (`:executable`, `:args`,
  `:env`); `runtime` the pinned identity (`"version"`, `"executable"`).
  Options: `:driver` (script path), `:python`, `:init_timeout`,
  `:request_timeout` (seconds), `:now`.
  """
  @spec observe(map(), Path.t(), map(), Path.t(), keyword()) :: [map()]
  def observe(context, cwd, runtime, dir, opts \\ []) do
    File.mkdir_p!(dir)
    production = context.args

    modes =
      case control_args(production) do
        {:ok, control} -> [{"scope-off", production, false}, {"scope-on", control, true}]
        {:error, reason} -> [{"scope-off", production, false, reason}]
      end

    modes
    |> Enum.map(fn
      {mode, args, enabled} ->
        Task.async(fn -> {mode, args, enabled, run_driver(context, args, cwd, opts)} end)

      {mode, args, enabled, reason} ->
        Task.async(fn -> {mode, args, enabled, %{"error" => reason}} end)
    end)
    |> Enum.map(&Task.await(&1, :infinity))
    |> Enum.map(fn {mode, args, enabled, raw} ->
      receipt = receipt(mode, args, enabled, raw, context, cwd, runtime, opts)
      bytes = Jason.encode!(receipt, pretty: true)
      path = Path.join(dir, mode <> ".json")
      File.write!(path, bytes)
      Map.merge(receipt, %{"path" => path, "sha256" => sha(bytes)})
    end)
  end

  @doc """
  The positive-control arguments: the production arguments with exactly the
  `--disable apps` and `--disable plugins` pairs switched to `--enable`.
  Production arguments that do not disable both refuse.
  """
  @spec control_args([String.t()]) :: {:ok, [String.t()]} | {:error, String.t()}
  def control_args(args) do
    if Enum.all?(@flags, &disabled?(args, &1)),
      do: {:ok, flip(args)},
      else: {:error, "production launch arguments do not disable apps and plugins"}
  end

  defp disabled?(args, flag),
    do: args |> Enum.chunk_every(2, 1, :discard) |> Enum.any?(&(&1 == ["--disable", flag]))

  defp flip(["--disable", flag | rest]) when flag in @flags, do: ["--enable", flag | flip(rest)]
  defp flip([arg | rest]), do: [arg | flip(rest)]
  defp flip([]), do: []

  @doc """
  The launch binding both sessions share: the arguments with the apps and
  plugins flags removed, the scope home and the working directory.
  """
  @spec launch_binding([String.t()], String.t() | nil, Path.t()) :: String.t()
  def launch_binding(args, codex_home, cwd),
    do: sha(Jason.encode!([strip(args), codex_home, Path.expand(cwd)]))

  defp strip([switch, flag | rest]) when switch in ["--enable", "--disable"] and flag in @flags,
    do: strip(rest)

  defp strip([arg | rest]), do: [arg | strip(rest)]
  defp strip([]), do: []

  @doc "Digest of an exact argument list."
  @spec args_sha256([String.t()]) :: String.t()
  def args_sha256(args), do: sha(Jason.encode!(args))

  @doc "The scope home the launch context selects."
  @spec codex_home(map()) :: String.t() | nil
  def codex_home(context) do
    Enum.find_value(context.env, fn
      {"CODEX_HOME", value} -> value
      _ -> nil
    end)
  end

  defp run_driver(context, args, cwd, opts) do
    driver =
      opts[:driver] ||
        Application.app_dir(:kogen, "priv/kogen/codex/compatibility/account_observation.py")

    spec =
      Jason.encode!(%{
        executable: context.executable,
        args: args,
        cwd: Path.expand(cwd),
        init_timeout: Keyword.get(opts, :init_timeout, 10),
        request_timeout: Keyword.get(opts, :request_timeout, 35)
      })

    python = opts[:python] || System.find_executable("python3")

    case System.cmd(python, ["-B", driver, spec], env: context.env, stderr_to_stdout: false) do
      {output, 0} ->
        case output |> String.split("\n", trim: true) |> List.last() |> decode() do
          {:ok, %{} = raw} -> raw
          _ -> %{"error" => "account observation driver produced no result"}
        end

      {_output, status} ->
        %{"error" => "account observation driver exited #{status}"}
    end
  rescue
    error -> %{"error" => "account observation failed: #{Exception.message(error)}"}
  end

  defp decode(nil), do: :error
  defp decode(line), do: Jason.decode(line)

  defp receipt(mode, args, enabled, raw, context, cwd, runtime, opts) do
    installed_apps = result(raw, "installed_apps", "apps")
    marketplaces = result(raw, "installed_plugins", "marketplaces")

    plugins =
      if is_list(marketplaces), do: Enum.flat_map(marketplaces, &(&1["plugins"] || [])), else: nil

    %{
      "mode" => mode,
      "flags" => %{"apps" => enabled, "plugins" => enabled},
      "runtime" => runtime["version"],
      "executable_sha256" => file_sha(context.executable),
      "pinned_executable_sha256" => file_sha(runtime["executable"]),
      "codex_home" => get_in(raw, ["initialize", "result", "codexHome"]),
      "selected_codex_home" => codex_home(context),
      "launch_binding" => launch_binding(args, codex_home(context), cwd),
      "args_sha256" => args_sha256(args),
      "account_fingerprint" => raw["account_fingerprint"],
      "installed_apps" => count(installed_apps, fn _ -> true end),
      "enabled_apps" => count(installed_apps, &(&1["enabled"] == true)),
      "callable_apps" => count(installed_apps, &(&1["callable"] == true)),
      "installed_plugin_count" => count(plugins, &(&1["installed"] == true)),
      "remote_enabled_plugins" => remote_enabled(plugins),
      "discovery" => get_in(raw, ["responses", "apps"]) || %{"missing" => true},
      "model_turns" => raw["model_turns"],
      "tool_calls" => raw["tool_calls"],
      "error" => raw["error"],
      "recorded_at" => now(opts[:now])
    }
  end

  defp result(raw, response, key) do
    case get_in(raw, ["responses", response]) do
      %{"result" => %{^key => value}} when is_list(value) -> value
      _ -> nil
    end
  end

  # A missing response is recorded as nil, never as zero.
  defp count(nil, _fun), do: nil
  defp count(list, fun), do: Enum.count(list, fun)

  defp remote_enabled(nil), do: nil

  defp remote_enabled(plugins) do
    for %{"id" => id} = plugin <- plugins,
        plugin["enabled"] == true,
        plugin["installed"] == true,
        get_in(plugin, ["source", "type"]) == "remote",
        do: id
  end

  defp now(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp now(_), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp file_sha(path) when is_binary(path) do
    case File.read(path) do
      {:ok, bytes} -> sha(bytes)
      _ -> nil
    end
  end

  defp file_sha(_), do: nil

  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end

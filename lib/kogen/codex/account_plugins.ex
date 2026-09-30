defmodule Kogen.Codex.AccountPlugins do
  @moduledoc """
  Honest, per-surface evaluation of account/remote plugin exclusion.

  Bundled `.system` skill classification is a different question and is never
  consulted here.  Nothing in this module derives one surface from another: a
  native app-server discovery result says nothing about what a model saw as
  root, helper, resume or interactive.

  Two receipt kinds are parsed from JSON:

    * native app-server receipts (`"mode"`, `"discovery"`, app/plugin counts,
      `"remote_enabled_plugins"`, `"account_fingerprint"`, ...), either single
      observations or the probe `summary.json` shape with an `"observations"`
      list plus top-level `"runtime"`, `"executable_sha256"`, `"recorded_at"`;
    * model-visible receipts (`"surface"`, `"session_id"`,
      `"executable_sha256"`, `"flags"`, `"visible_plugins"`, `"visible_apps"`).

  Anything else (for instance a bare `{"visible_plugins": []}`) is rejected as
  unrecognized and proves nothing.
  """

  use Boundary, top_level?: true, deps: []

  @surfaces ~w(native_discovery root helper resume interactive)
  @model_surfaces ~w(root helper resume interactive)
  @default_max_age 7 * 24 * 3600

  @spec surfaces() :: [String.t()]
  def surfaces, do: @surfaces

  @doc "Parses a decoded JSON receipt into a list of tagged observations."
  @spec parse(term()) :: {:ok, [map()]} | {:error, atom()}
  def parse(%{"observations" => list} = top) when is_list(list) do
    inherited = Map.take(top, ~w(runtime executable_sha256 recorded_at))

    results = Enum.map(list, &parse_one(Map.merge(inherited, drop_nil(&1))))

    case Enum.filter(results, &match?({:ok, _}, &1)) do
      [] -> {:error, :unrecognized_receipt}
      oks -> {:ok, Enum.map(oks, fn {:ok, o} -> o end)}
    end
  end

  def parse(map) when is_map(map) do
    case parse_one(map) do
      {:ok, observation} -> {:ok, [observation]}
      error -> error
    end
  end

  def parse(_), do: {:error, :unrecognized_receipt}

  defp drop_nil(map) when is_map(map), do: map
  defp drop_nil(_), do: %{}

  defp parse_one(%{"surface" => surface} = map) when surface in @model_surfaces do
    {:ok,
     %{
       kind: :model,
       surface: surface,
       session_id: string(map["session_id"]),
       runtime: string(map["runtime"]),
       sha: string(map["executable_sha256"]),
       flags_disabled: flags_disabled?(map["flags"]),
       visible: visible_names(map),
       recorded_at: time(map["recorded_at"])
     }}
  end

  defp parse_one(%{"mode" => mode} = map) when is_binary(mode) do
    {home, state} = split_mode(mode, map["flags"])

    {:ok,
     %{
       kind: :native,
       mode: mode,
       home: home,
       enabled: state == :on,
       state: state,
       runtime: string(map["runtime"]),
       sha: string(map["executable_sha256"]),
       fingerprint: string(map["account_fingerprint"]),
       enabled_apps: int(map["enabled_apps"]),
       callable_apps: int(map["callable_apps"]),
       installed_plugins: int(map["installed_plugin_count"]),
       remote_plugins: names(map["remote_enabled_plugins"]),
       discovery: discovery(map["discovery"]),
       recorded_at: time(map["recorded_at"]),
       codex_home: path(map["codex_home"]),
       selected_codex_home: path(map["selected_codex_home"]),
       launch_binding: string(map["launch_binding"]),
       args_sha: string(map["args_sha256"]),
       error: string(map["error"])
     }}
  end

  defp parse_one(_), do: {:error, :unrecognized_receipt}

  defp path(value) when is_binary(value) and value != "", do: Path.expand(value)
  defp path(_), do: nil

  defp split_mode(mode, flags) do
    {home, suffix} =
      case String.split(mode, "-") do
        [h, s] -> {h, s}
        _ -> {nil, nil}
      end

    state =
      cond do
        is_map(flags) -> if flags_disabled?(flags), do: :off, else: :on
        suffix == "off" -> :off
        suffix == "on" -> :on
        true -> :unknown
      end

    {home, state}
  end

  defp flags_disabled?(%{"apps" => false, "plugins" => false}), do: true
  defp flags_disabled?(_), do: false

  defp discovery(%{"timeout" => true}), do: :timeout
  defp discovery(%{"error" => _}), do: :error
  defp discovery(%{"result" => %{"data" => []}}), do: :empty
  defp discovery(%{"result" => %{"data" => [_ | _] = data}}), do: {:data, data}
  defp discovery(_), do: :missing

  defp visible_names(map) do
    plugins = map["visible_plugins"]
    apps = map["visible_apps"]

    if is_list(plugins) and (is_list(apps) or is_nil(apps)),
      do: names(plugins) ++ names(apps || []),
      else: nil
  end

  defp names(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp names(_), do: []
  defp string(v) when is_binary(v) and v != "", do: v
  defp string(_), do: nil
  defp int(v) when is_integer(v), do: v
  defp int(_), do: nil

  defp time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp time(_), do: nil

  @doc """
  Evaluates parsed observations.

  Options: `:runtime` (pinned version), `:executable_sha256` (pinned),
  `:now` (DateTime or zero-arity function), `:max_age_seconds`.
  """
  @spec evaluate([map()], keyword()) :: map()
  def evaluate(observations, opts \\ []) when is_list(observations) do
    ctx = %{
      runtime: opts[:runtime],
      sha: opts[:executable_sha256],
      now: now(opts[:now]),
      max_age: Keyword.get(opts, :max_age_seconds, @default_max_age),
      codex_home: path(opts[:codex_home]),
      launch_binding: opts[:launch_binding],
      production_args: opts[:production_args_sha256]
    }

    natives = Enum.filter(observations, &(&1.kind == :native))
    models = Enum.filter(observations, &(&1.kind == :model))
    controls = positive_controls(natives, ctx)

    surfaces =
      Map.new(@surfaces, fn
        "native_discovery" = s -> {s, native_discovery(natives, controls, ctx)}
        s -> {s, model_surface(s, Enum.filter(models, &(&1.surface == s)), controls, ctx)}
      end)

    statuses = Map.new(surfaces, fn {k, v} -> {k, v["status"]} end)
    leaked = for {k, "leaked"} <- statuses, do: k
    unproven = for {k, "unproven"} <- statuses, do: k

    status =
      cond do
        leaked != [] -> "leaked"
        unproven != [] -> "unproven"
        true -> "excluded"
      end

    %{
      "status" => status,
      "surfaces" => surfaces,
      "leaked_surfaces" => Enum.sort(leaked),
      "unproven_surfaces" => Enum.sort(unproven),
      "max_age_seconds" => ctx.max_age
    }
  end

  defp now(nil), do: DateTime.utc_now()
  defp now(fun) when is_function(fun, 0), do: fun.()
  defp now(%DateTime{} = dt), do: dt

  defp unproven(reason), do: %{"status" => "unproven", "reason" => reason}

  # Binding: runtime + sha match the pinned runtime; freshness separate.
  defp binding_error(o, ctx) do
    cond do
      is_nil(ctx.runtime) or is_nil(ctx.sha) -> "no_pinned_runtime"
      is_nil(o.sha) or o.sha != ctx.sha -> "executable_sha256_mismatch"
      is_nil(o.runtime) or o.runtime != ctx.runtime -> "runtime_version_mismatch"
      scope_error(o, ctx) -> scope_error(o, ctx)
      true -> nil
    end
  end

  # With a selected scope and launch binding (the production evaluation),
  # an observation counts only when the server itself reported that scope
  # home and the session ran the same effective launch as its pair.
  defp scope_error(%{kind: :native} = o, ctx) do
    cond do
      ctx.codex_home &&
          (o.codex_home != ctx.codex_home or o.selected_codex_home != ctx.codex_home) ->
        "codex_home_mismatch"

      ctx.launch_binding && o.launch_binding != ctx.launch_binding ->
        "launch_binding_mismatch"

      true ->
        nil
    end
  end

  defp scope_error(_o, _ctx), do: nil

  defp freshness_error(o, ctx) do
    cond do
      is_nil(o.recorded_at) -> "missing_recorded_at"
      DateTime.diff(ctx.now, o.recorded_at) > ctx.max_age -> "stale_observation"
      DateTime.diff(ctx.now, o.recorded_at) < -300 -> "recorded_in_future"
      true -> nil
    end
  end

  defp positive_controls(natives, ctx) do
    Enum.filter(natives, fn o ->
      o.enabled and o.remote_plugins != [] and o.fingerprint != nil and
        binding_error(o, ctx) == nil and freshness_error(o, ctx) == nil
    end)
  end

  defp native_discovery(natives, controls, ctx) do
    disabled =
      Enum.filter(natives, &(&1.state == :off and &1.home in [nil, "managed", "scope"]))

    if disabled == [] do
      unproven("no_disabled_observation")
    else
      results = Enum.map(disabled, &native_disabled(&1, controls, ctx))

      Enum.find(results, &(&1["status"] == "leaked")) ||
        Enum.find(results, &(&1["status"] == "excluded")) ||
        hd(results)
    end
  end

  defp native_disabled(o, controls, ctx) do
    counts = [o.enabled_apps, o.callable_apps, o.installed_plugins]

    case native_disabled_problem(o, ctx, counts) do
      :leaked ->
        %{
          "status" => "leaked",
          "mode" => o.mode,
          "reason" => "disabled_observation_shows_apps_or_plugins"
        }

      {:unproven, reason} ->
        unproven(reason)

      nil ->
        native_disabled_control(o, controls)
    end
  end

  defp native_disabled_problem(o, ctx, counts) do
    case native_disabled_scope_problem(o, ctx) do
      nil -> native_disabled_body_problem(o, ctx, counts)
      problem -> problem
    end
  end

  defp native_disabled_scope_problem(o, ctx) do
    binding = binding_error(o, ctx)

    cond do
      binding ->
        {:unproven, binding}

      ctx.production_args && o.args_sha != ctx.production_args ->
        {:unproven, "not_production_arguments"}

      true ->
        nil
    end
  end

  defp native_disabled_body_problem(o, ctx, counts) do
    cond do
      freshness_error(o, ctx) -> {:unproven, freshness_error(o, ctx)}
      native_disabled_leak?(o) -> :leaked
      true -> native_disabled_data_problem(o, counts)
    end
  end

  defp native_disabled_data_problem(o, counts) do
    cond do
      is_binary(o[:error]) -> {:unproven, "observation_error: " <> o.error}
      o.discovery == :timeout -> {:unproven, "discovery_timeout"}
      o.discovery == :error -> {:unproven, "discovery_error"}
      o.discovery != :empty -> {:unproven, "discovery_missing"}
      Enum.any?(counts, &is_nil/1) -> {:unproven, "incomplete_counts"}
      is_nil(o.fingerprint) -> {:unproven, "missing_account_fingerprint"}
      true -> nil
    end
  end

  defp native_disabled_leak?(o) do
    (o.enabled_apps || 0) > 0 or (o.callable_apps || 0) > 0 or
      (o.installed_plugins || 0) > 0 or o.remote_plugins != [] or
      match?({:data, _}, o.discovery)
  end

  defp native_disabled_control(o, controls) do
    case Enum.find(controls, &(&1.fingerprint == o.fingerprint)) do
      nil ->
        unproven("no_positive_control")

      control ->
        %{"status" => "excluded", "mode" => o.mode, "control_mode" => control.mode}
    end
  end

  defp model_surface(_surface, [], _controls, _ctx), do: unproven("no model-visible observation")

  defp model_surface(_surface, observations, controls, ctx) do
    control_names = controls |> Enum.flat_map(& &1.remote_plugins) |> Enum.uniq()
    results = Enum.map(observations, &model_one(&1, control_names, ctx))

    Enum.find(results, &(&1["status"] == "leaked")) ||
      Enum.find(results, &(&1["status"] == "excluded")) || hd(results)
  end

  defp model_one(o, control_names, ctx) do
    if control_names == [],
      do: unproven("no_positive_control"),
      else: model_validation_result(o, control_names, ctx)
  end

  defp model_validation_result(o, control_names, ctx) do
    case model_validation(o, ctx) do
      %{"status" => "unproven"} = result ->
        result

      %{"status" => "excluded"} = result ->
        overlap = overlap(o.visible, control_names)

        if overlap == [],
          do: result,
          else: %{"status" => "leaked", "visible_enabled_plugins" => overlap}
    end
  end

  defp model_validation(o, ctx) do
    cond do
      binding_error(o, ctx) -> unproven(binding_error(o, ctx))
      is_nil(o.session_id) -> unproven("missing_session_id")
      not o.flags_disabled -> unproven("effective_flags_not_disabled")
      is_nil(o.visible) -> unproven("missing_visible_lists")
      freshness_error(o, ctx) -> unproven(freshness_error(o, ctx))
      true -> %{"status" => "excluded", "session_id" => o.session_id}
    end
  end

  defp overlap(visible, control_names) do
    short = MapSet.new(control_names, &(&1 |> String.split("@") |> hd()))
    full = MapSet.new(control_names)

    visible
    |> Enum.filter(&(MapSet.member?(full, &1) or MapSet.member?(short, &1)))
    |> Enum.uniq()
  end

  @doc """
  Reads every `*.json` file in `dir`, returning `{observations, receipts}`.
  Each receipt records path, sha256 and whether it was recognized.  A missing
  directory yields no observations (hence `unproven`).
  """
  @spec read_dir(String.t() | nil) :: {[map()], [map()]}
  def read_dir(dir) when is_binary(dir) do
    dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reduce({[], []}, &read_receipt/2)
  end

  def read_dir(_), do: {[], []}

  defp read_receipt(path, {observations, receipts}) do
    case File.read(path) do
      {:ok, body} -> append_receipt(path, body, observations, receipts)
      _ -> {observations, receipts ++ [%{"path" => path, "sha256" => nil, "recognized" => false}]}
    end
  end

  defp append_receipt(path, body, observations, receipts) do
    sha = Base.encode16(:crypto.hash(:sha256, body), case: :lower)

    case decode_receipt(body) do
      {:ok, list} ->
        {observations ++ list,
         receipts ++ [%{"path" => path, "sha256" => sha, "recognized" => true}]}

      _ ->
        {observations, receipts ++ [%{"path" => path, "sha256" => sha, "recognized" => false}]}
    end
  end

  defp decode_receipt(body) do
    with {:ok, decoded} <- Jason.decode(body), do: parse(decoded)
  end

  @doc "Reads `dir` and evaluates, attaching receipt provenance."
  @spec evaluate_dir(String.t() | nil, keyword()) :: map()
  def evaluate_dir(dir, opts \\ []) do
    {observations, receipts} = read_dir(dir)

    observations
    |> evaluate(opts)
    |> Map.merge(%{"observation_dir" => dir, "receipts" => receipts})
  end
end

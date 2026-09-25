defmodule Kogen.Codex.Environment do
  @moduledoc false
  alias Kogen.Codex.State

  # This module deliberately returns a System.cmd environment *delta*.  Entries
  # with nil remove inherited values; leaving an entry out would accidentally
  # leave a personal provider or Codex setting visible to the managed runtime.
  @private_xdg ["XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME"]

  @blocked_prefixes ["CODEX_", "OPENAI_", "AZURE_", "ANTHROPIC_", "CHATGPT_"]

  @tool_output_token_limit 4000

  @executor_environment "environments.toml"
  @executor_entrypoint "executor"
  @executor_variables [
    "KOGEN_CODEX_EXECUTOR_ENTRYPOINT",
    "KOGEN_CODEX_EXECUTABLE",
    "KOGEN_CODEX_EXECUTOR_LAUNCH_MARKER"
  ]

  @blocked_names MapSet.new([
                   "API_KEY",
                   "OPENAI_API_KEY",
                   "OPENAI_BASE_URL",
                   "OPENAI_ORG_ID",
                   "OPENAI_ORGANIZATION",
                   "OPENAI_PROJECT",
                   "AZURE_OPENAI_API_KEY",
                   "AZURE_OPENAI_ENDPOINT",
                   "ANTHROPIC_API_KEY",
                   "ANTHROPIC_BASE_URL",
                   "CLAUDE_CODE_OAUTH_TOKEN",
                   "CLAUDE_CODE_USE_BEDROCK",
                   "CLAUDE_CODE_USE_VERTEX",
                   "CHATGPT_API_KEY"
                 ])

  @doc "Prepares one isolated native Codex launch."
  @spec prepare(map(), map(), :setup | map(), Path.t(), Path.t()) :: %{
          executable: String.t(),
          args: [String.t()],
          env: [{String.t(), String.t() | nil}]
        }
  def prepare(
        runtime,
        scope,
        config,
        project_root,
        invocation_root,
        caller_env \\ System.get_env()
      )
      when is_map(runtime) and is_map(scope) and is_binary(project_root) and
             is_binary(invocation_root) do
    executable = Map.fetch!(runtime, "executable")
    scope_home = Map.fetch!(scope, :path)

    validate_directory!("project root", project_root)
    validate_directory!("invocation root", invocation_root)
    validate_scope!(scope_home)

    caller = caller_environment(caller_env)
    generation = fresh_generation!(invocation_root)
    private_home = Path.join(generation, "home")
    private_xdg = private_xdg(generation)
    sqlite_home = Path.join([invocation_root, "state", "sqlite"])

    State.private_directory!(sqlite_home)

    Enum.each([private_home | Map.values(private_xdg)], fn path ->
      File.mkdir_p!(path)
      File.chmod!(path, 0o700)
    end)

    helper_files = write_helper_profiles!(generation, config)
    ensure_executor_registry!(scope_home)
    ensure_agent_definitions!(scope_home)
    executor = write_executor_entrypoint!(generation)

    context = %{
      executable: executable,
      args:
        retained_trust_args(scope_home, project_root) ++
          config_args(config, project_root, helper_files, sqlite_home, caller),
      env:
        (caller_delta(caller_env) ++
           sanitizer_delta(caller_env) ++
           [
             {"CODEX_HOME", scope_home},
             {"KOGEN_PROJECT_ROOT", project_root},
             {"HOME", private_home},
             {"XDG_CONFIG_HOME", private_xdg["XDG_CONFIG_HOME"]},
             {"XDG_DATA_HOME", private_xdg["XDG_DATA_HOME"]},
             {"XDG_CACHE_HOME", private_xdg["XDG_CACHE_HOME"]},
             {"XDG_STATE_HOME", private_xdg["XDG_STATE_HOME"]},
             {"SQLITE_HOME", sqlite_home},
             {"KOGEN_ENV_RESTORE_PENDING", "1"},
             {"KOGEN_CALLER_HOME", caller.home},
             {"KOGEN_CODEX_EXECUTOR_ENTRYPOINT", executor},
             {"KOGEN_CODEX_EXECUTABLE", executable},
             {"KOGEN_CODEX_EXECUTOR_LAUNCH_MARKER", "1"}
           ] ++ caller_xdg_delta(caller))
        |> Map.new()
        |> Map.to_list()
    }

    retain_test_context(context, caller_env)
    context
  end

  # The live fixture owns exact-reply transport after its interactive terminal
  # closes. Retain the already-selected immutable context only when that
  # explicit test boundary is supplied; ordinary launches create no receipt.
  defp retain_test_context(context, %{"KOGEN_CODEX_CONTEXT_RECEIPT" => path})
       when is_binary(path) and path != "" do
    # Jason deliberately does not encode Elixir tuples. Keep the production
    # System.cmd delta as tuples, but make the retained cross-language boundary
    # explicit: managed_resume.py consumes two-element JSON arrays and must
    # preserve nil (unset), empty, and populated values distinctly.
    retained = %{context | env: Enum.map(context.env, fn {name, value} -> [name, value] end)}
    File.write!(path, Jason.encode!(retained), [:exclusive])
  end

  defp retain_test_context(_context, _environment), do: :ok

  defp caller_environment(environment) do
    %{
      home: environment["HOME"] || "",
      xdg: Map.new(@private_xdg, &{&1, environment[&1]})
    }
  end

  defp caller_xdg_delta(caller) do
    Enum.flat_map(@private_xdg, fn name ->
      marker = "KOGEN_CALLER_" <> name

      case caller.xdg[name] do
        nil -> [{marker, nil}, {marker <> "_ABSENT", "1"}, {marker <> "_EMPTY", nil}]
        "" -> [{marker, nil}, {marker <> "_ABSENT", nil}, {marker <> "_EMPTY", "1"}]
        value -> [{marker, value}, {marker <> "_ABSENT", nil}, {marker <> "_EMPTY", nil}]
      end
    end)
  end

  defp fresh_generation!(invocation_root) do
    parent = Path.join(invocation_root, "generations")
    State.private_directory!(parent)
    create_generation!(parent)
  end

  defp create_generation!(parent) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    generation = Path.join(parent, token)

    case File.mkdir(generation) do
      :ok ->
        File.chmod!(generation, 0o700)
        generation

      {:error, :eexist} ->
        create_generation!(parent)

      {:error, reason} ->
        raise File.Error,
          reason: reason,
          action: "create private Codex generation",
          path: generation
    end
  end

  defp private_xdg(generation) do
    %{
      "XDG_CONFIG_HOME" => Path.join(generation, "xdg-config"),
      "XDG_DATA_HOME" => Path.join(generation, "xdg-data"),
      "XDG_CACHE_HOME" => Path.join(generation, "xdg-cache"),
      "XDG_STATE_HOME" => Path.join(generation, "xdg-state")
    }
  end

  # Each file is a launch snapshot.  Native helpers read only the snapshot they
  # were handed, so a later prepare cannot change an active invocation.
  # Setup operations (install, login, status and readiness probes) declare with
  # `:setup` that they carry no role profiles and get no helper-profile files.
  # A role launch needs every helper's model and effort from its resolved route;
  # an incomplete profile fails loudly rather than writing an empty one.
  defp write_helper_profiles!(_generation, :setup), do: %{}

  # The expert profile is native only when the route assigns the Expert role to
  # Codex; a harness view without it gets no expert helper, never a substitute.
  defp write_helper_profiles!(generation, config) do
    helpers = if is_map(config), do: value(config, :helpers)
    expert = if is_map(helpers) and has_value?(helpers, :expert), do: [:expert], else: []

    Enum.into([:scout, :worker] ++ expert, %{}, fn role ->
      {model, effort} = helper_profile!(config, role)
      path = Path.join(generation, "#{role}.toml")
      content = "model = #{toml(model)}\nmodel_reasoning_effort = #{toml(effort)}\n"

      File.write!(path, content)
      {role, path}
    end)
  end

  defp helper_profile!(config, role) do
    helpers = if is_map(config), do: value(config, :helpers)
    profile = if is_map(helpers), do: value(helpers, role)
    model = if is_map(profile), do: value(profile, :model)
    effort = if is_map(profile), do: value(profile, :effort)

    if nonblank?(model) and nonblank?(effort) do
      {model, effort}
    else
      raise ArgumentError,
            "Codex role launch requires a complete helpers.#{role} profile (model and effort)"
    end
  end

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""

  defp has_value?(map, key), do: Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))

  # The registry belongs to the selected credential scope, not to an operation.
  # Per-launch data must never be written here because native app-server instances
  # can read it concurrently. The shell text is intentionally constant: it only
  # dereferences an environment variable Kogen sets after removing inherited
  # executor settings.
  defp ensure_executor_registry!(scope_home) do
    path = Path.join(scope_home, @executor_environment)
    expected = executor_registry_contents()

    case File.lstat(path) do
      {:error, :enoent} ->
        temporary =
          path <> "." <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

        try do
          File.write!(temporary, expected, [:exclusive])
          File.chmod!(temporary, 0o600)

          case File.ln(temporary, path) do
            :ok ->
              :ok

            {:error, :eexist} ->
              ensure_executor_registry!(scope_home)

            {:error, reason} ->
              raise File.Error,
                reason: reason,
                action: "create managed executor registry",
                path: path
          end
        after
          File.rm(temporary)
        end

      {:ok, %{type: :regular}} ->
        if File.read!(path) != expected do
          raise "incompatible managed executor registry: #{path}"
        end

      _ ->
        raise "unexpected managed executor registry: #{path}"
    end
  end

  # Codex 0.154 exposes its built-in explorer/worker/default routing only when
  # standalone agent discovery is active. A single unrelated Kogen definition
  # activates that discovery without replacing the built-in kinds. Its bytes are
  # static across operations, so overlapping launches never rewrite active state.
  defp ensure_agent_definitions!(scope_home) do
    directory = Path.join(scope_home, "agents")
    State.private_directory!(directory)
    path = Path.join(directory, "kogen_boundary.toml")

    expected = """
    name = "kogen_boundary"
    description = "Kogen managed discovery marker; built-in helper roles remain authoritative"
    developer_instructions = "Do not select this marker for delegated work."
    """

    case File.read(path) do
      {:ok, ^expected} ->
        :ok

      {:ok, _other} ->
        raise "unexpected managed Codex agent definition at #{path}"

      {:error, :enoent} ->
        temporary =
          path <> "." <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

        try do
          File.write!(temporary, expected, [:exclusive])
          File.chmod!(temporary, 0o600)

          case File.ln(temporary, path) do
            :ok ->
              :ok

            {:error, :eexist} ->
              ensure_agent_definitions!(scope_home)

            {:error, reason} ->
              raise File.Error,
                reason: reason,
                action: "publish managed Codex agent definition",
                path: path
          end
        after
          File.rm(temporary)
        end

      {:error, reason} ->
        raise File.Error,
          reason: reason,
          action: "inspect managed Codex agent definition",
          path: path
    end
  end

  defp executor_registry_contents do
    ~S"""
    default = "kogen"
    include_local = false
    [[environments]]
    id = "kogen"
    program = "/bin/sh"
    args = ["-c", "exec \"${KOGEN_CODEX_EXECUTOR_ENTRYPOINT:?missing managed launch context}\""]
    """
  end

  # This file contains no caller values. Its directory is a unique private
  # generation, so the executable snapshot cannot change while native owns it.
  defp write_executor_entrypoint!(generation) do
    path = Path.join(generation, @executor_entrypoint)
    File.write!(path, executor_entrypoint_contents(), [:exclusive])
    File.chmod!(path, 0o700)
    path
  end

  defp executor_entrypoint_contents do
    """
    #!/bin/sh
    set -eu

    fail() { echo "Kogen managed executor: $1" >&2; exit 126; }

    [ "${KOGEN_CODEX_EXECUTOR_LAUNCH_MARKER:-}" = "1" ] || fail "missing launch marker"
    [ -n "${KOGEN_CODEX_EXECUTOR_ENTRYPOINT:-}" ] || fail "missing entrypoint marker"
    [ "$KOGEN_CODEX_EXECUTOR_ENTRYPOINT" = "$0" ] || fail "entrypoint marker mismatch"
    [ -n "${KOGEN_CODEX_EXECUTABLE:-}" ] || fail "missing native executable"
    case "$KOGEN_CODEX_EXECUTABLE" in /*) ;; *) fail "native executable must be absolute" ;; esac
    [ -n "${CODEX_HOME:-}" ] || fail "missing credential scope"
    [ -n "${KOGEN_CALLER_HOME+x}" ] || fail "missing caller HOME"

    export HOME="$KOGEN_CALLER_HOME"

    restore_xdg_config() {
      if [ "${KOGEN_CALLER_XDG_CONFIG_HOME_ABSENT:-}" = "1" ]; then
        [ -z "${KOGEN_CALLER_XDG_CONFIG_HOME_EMPTY:-}" ] || fail "conflicting caller XDG_CONFIG_HOME markers"
        unset XDG_CONFIG_HOME
      elif [ "${KOGEN_CALLER_XDG_CONFIG_HOME_EMPTY:-}" = "1" ]; then
        export XDG_CONFIG_HOME=""
      else
        [ -n "${KOGEN_CALLER_XDG_CONFIG_HOME+x}" ] || fail "missing caller XDG_CONFIG_HOME marker"
        export XDG_CONFIG_HOME="$KOGEN_CALLER_XDG_CONFIG_HOME"
      fi
    }

    restore_xdg_data() {
      if [ "${KOGEN_CALLER_XDG_DATA_HOME_ABSENT:-}" = "1" ]; then
        [ -z "${KOGEN_CALLER_XDG_DATA_HOME_EMPTY:-}" ] || fail "conflicting caller XDG_DATA_HOME markers"
        unset XDG_DATA_HOME
      elif [ "${KOGEN_CALLER_XDG_DATA_HOME_EMPTY:-}" = "1" ]; then
        export XDG_DATA_HOME=""
      else
        [ -n "${KOGEN_CALLER_XDG_DATA_HOME+x}" ] || fail "missing caller XDG_DATA_HOME marker"
        export XDG_DATA_HOME="$KOGEN_CALLER_XDG_DATA_HOME"
      fi
    }

    restore_xdg_cache() {
      if [ "${KOGEN_CALLER_XDG_CACHE_HOME_ABSENT:-}" = "1" ]; then
        [ -z "${KOGEN_CALLER_XDG_CACHE_HOME_EMPTY:-}" ] || fail "conflicting caller XDG_CACHE_HOME markers"
        unset XDG_CACHE_HOME
      elif [ "${KOGEN_CALLER_XDG_CACHE_HOME_EMPTY:-}" = "1" ]; then
        export XDG_CACHE_HOME=""
      else
        [ -n "${KOGEN_CALLER_XDG_CACHE_HOME+x}" ] || fail "missing caller XDG_CACHE_HOME marker"
        export XDG_CACHE_HOME="$KOGEN_CALLER_XDG_CACHE_HOME"
      fi
    }

    restore_xdg_state() {
      if [ "${KOGEN_CALLER_XDG_STATE_HOME_ABSENT:-}" = "1" ]; then
        [ -z "${KOGEN_CALLER_XDG_STATE_HOME_EMPTY:-}" ] || fail "conflicting caller XDG_STATE_HOME markers"
        unset XDG_STATE_HOME
      elif [ "${KOGEN_CALLER_XDG_STATE_HOME_EMPTY:-}" = "1" ]; then
        export XDG_STATE_HOME=""
      else
        [ -n "${KOGEN_CALLER_XDG_STATE_HOME+x}" ] || fail "missing caller XDG_STATE_HOME marker"
        export XDG_STATE_HOME="$KOGEN_CALLER_XDG_STATE_HOME"
      fi
    }

    restore_xdg_config
    restore_xdg_data
    restore_xdg_cache
    restore_xdg_state

    exec "$KOGEN_CODEX_EXECUTABLE" exec-server --listen stdio
    """
  end

  defp retained_trust_args(scope_home, project_root) do
    scope_home
    |> State.native_projects!()
    |> Enum.reject(&(&1 == project_root))
    |> Enum.flat_map(&["-c", "projects.#{toml(&1)}.trust_level=\"untrusted\""])
  end

  defp config_args(_config, project_root, helpers, sqlite_home, caller) do
    shell_excludes = Enum.map_join(@private_xdg, ", ", &toml/1)

    base = [
      "cli_auth_credentials_store=\"file\"",
      "check_for_update_on_startup=false",
      "project_root_markers=[\".git\"]",
      "projects.#{toml(project_root)}.trust_level=\"trusted\"",
      "shell_environment_policy.inherit=\"all\"",
      "shell_environment_policy.exclude=[#{shell_excludes}]",
      "shell_environment_policy.set.HOME=#{toml(caller.home)}",
      "shell_environment_policy.experimental_use_profile=false",
      "sqlite_home=#{toml(sqlite_home)}",
      # One central bound, about Claude Code's Bash result cap, so a role or
      # helper tool result cannot be re-sent in full on every later step.
      "tool_output_token_limit=#{@tool_output_token_limit}"
    ]

    caller_xdg =
      for name <- @private_xdg, value = caller.xdg[name], not is_nil(value) do
        "shell_environment_policy.set.#{name}=#{toml(value)}"
      end

    helper_profiles =
      for role <- [:scout, :worker, :expert],
          path = Map.get(helpers, role),
          not is_nil(path),
          setting <- [
            "agents.#{role}.config_file=#{toml(path)}",
            "agents.#{role}.description=#{toml(helper_description(role))}"
          ],
          do: setting

    config_args = Enum.flat_map(base ++ caller_xdg ++ helper_profiles, &["-c", &1])
    ["--disable", "apps", "--disable", "plugins", "--disable", "shell_snapshot" | config_args]
  end

  defp helper_description(:scout),
    do:
      "Read-only focused discovery. Use the configured scout profile; never run verification gates."

  defp helper_description(:worker),
    do:
      "Bounded implementation in assigned files. Preserve other edits; never run verification gates."

  defp helper_description(:expert),
    do:
      "One named difficult uncertainty. Use the configured expert profile; never run verification gates."

  defp toml(value), do: Jason.encode!(to_string(value))

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp caller_delta(environment), do: Map.to_list(environment)

  defp sanitizer_delta(environment) do
    Map.merge(System.get_env(), environment)
    |> Map.keys()
    |> Enum.filter(&blocked_environment?/1)
    |> Enum.map(&{&1, nil})
  end

  defp blocked_environment?(name) do
    MapSet.member?(@blocked_names, name) or
      name in @executor_variables or
      String.starts_with?(name, "KOGEN_CALLER_") or
      Enum.any?(@blocked_prefixes, &String.starts_with?(name, &1))
  end

  defp validate_directory!(label, path) do
    expanded = Path.expand(path)

    directory? =
      case File.lstat(path) do
        {:ok, stat} -> stat.type == :directory
        _ -> false
      end

    if path != expanded or not directory? do
      raise "Kogen Codex #{label} must be an existing canonical directory: #{path}"
    end
  end

  defp validate_scope!(path) do
    validate_directory!("credential scope", path)

    State.validate_scope!(path)
  end
end

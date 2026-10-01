defmodule Kogen.RoleConfig do
  use Boundary, deps: []

  @moduledoc """
  Resolves per-project custom role profiles into an immutable, JSON-safe value.

  This is deliberately a configuration leaf: it reads one project config and
  prompt files, performs local validation, and never consults credentials or a
  provider. Run admission owns persistence and resume must use this frozen map.
  """

  @roles ~w(shaping developer reviewer auditor expert)
  @tools ~w(read write edit bash)
  @read_only_tools ~w(read bash)
  @prompt_identities @roles
  @schema_version 1
  @max_config_bytes 262_144
  @max_prompt_bytes 131_072
  @sha256 ~r/\A[a-f0-9]{64}\z/
  @name ~r/\A[a-z][a-z0-9_-]{0,63}\z/

  # The custom ChatGPT adapter in pinned kh exposes this effort map. Restrict
  # model ids to the documented custom ChatGPT family; other model-table
  # entries require a different provider and are not dispatchable here.
  @chatgpt_model_efforts %{
    "gpt-6-luna" => ~w(low medium high xhigh),
    "gpt-6.1-sol" => ~w(low medium high xhigh),
    "gpt-6-astra" => ~w(low medium high xhigh)
  }
  @supported_models @chatgpt_model_efforts

  @secret_patterns [
    ~r/(?i)(?:sk-[a-z0-9_-]{16,}|gh[pousr]_[a-z0-9]{20,}|Bearer\s+[a-z0-9._-]{12,})/,
    ~r/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/,
    ~r/(?i)(?:api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret)\s*:/
  ]
  @yaml_mapping_line ~r/\A( *)([A-Za-z_][A-Za-z0-9_-]*):(.*)\z/
  @yaml_plain_scalar ~r/\A[A-Za-z0-9][A-Za-z0-9._:\x2f\x23-]*\z/
  @yaml_double_scalar ~r/\A"(?:[^"\\]|\\.)*"\z/
  @yaml_single_scalar ~r/\A'(?:[^']|'')*'\z/
  @yaml_tools_sequence ~r/\A\[\s*(?:[A-Za-z][A-Za-z0-9_-]*(?:\s*,\s*[A-Za-z][A-Za-z0-9_-]*)*)?\s*\]\z/

  @builtin_profiles %{
    "shaping" => %{
      "model" => "gpt-6-luna",
      "effort" => "medium",
      "prompt" => "shaping",
      "tools" => ~w(read write edit bash),
      "context" => "full"
    },
    "developer" => %{
      "model" => "gpt-6-luna",
      "effort" => "medium",
      "prompt" => "developer",
      "tools" => ~w(read write edit bash),
      "context" => "full"
    },
    "reviewer" => %{
      "model" => "gpt-6.1-sol",
      "effort" => "high",
      "prompt" => "reviewer",
      "tools" => ~w(read bash),
      "context" => "full"
    },
    "auditor" => %{
      "model" => "gpt-6.1-sol",
      "effort" => "high",
      "prompt" => "auditor",
      "tools" => ~w(read bash),
      "context" => "full"
    },
    "expert" => %{
      "model" => "gpt-6.1-sol",
      "effort" => "high",
      "prompt" => "expert",
      "tools" => ~w(read bash),
      "context" => "full"
    }
  }

  @frozen_keys ~w(
    schema project_identity configuration_name configuration_source
    configuration_raw_sha256 roles effective_fingerprint
  )
  @frozen_profile_keys ~w(model effort prompt tools context)

  @doc "Resolve one configuration and freeze every selected role's exact prompt bytes."
  @spec resolve(Path.t(), Path.t(), String.t() | nil) ::
          {:ok, map()} | {:error, String.t()}
  def resolve(project_root, engine_root, configuration_name \\ nil) do
    with {:ok, project_identity} <- canonical_directory(project_root, "project root"),
         {:ok, engine_identity} <- canonical_directory(engine_root, "engine root"),
         {:ok, source} <- load_configuration(project_identity),
         {:ok, name, all_profiles} <- configuration_profiles(source),
         {:ok, selected_name} <- select_configuration(name, all_profiles, configuration_name),
         {:ok, validated} <-
           validate_all_profiles(all_profiles, project_identity, engine_identity),
         {:ok, frozen_roles} <- freeze_roles(Map.fetch!(validated, selected_name)),
         frozen = %{
           "schema" => @schema_version,
           "project_identity" => project_identity,
           "configuration_name" => selected_name,
           "configuration_source" => source.source,
           "configuration_raw_sha256" => source.raw_sha256,
           "roles" => frozen_roles
         },
         frozen = Map.put(frozen, "effective_fingerprint", fingerprint(frozen)),
         :ok <- validate_frozen(frozen) do
      {:ok, frozen}
    end
  rescue
    _error in [KeyError, ArgumentError] -> {:error, "custom role configuration is malformed"}
  end

  @doc "Validate a frozen role map without reading the project's live config or prompts."
  @spec validate_frozen(term()) :: :ok | {:error, String.t()}
  def validate_frozen(frozen) when is_map(frozen) do
    with :ok <- exact_keys(frozen, @frozen_keys, "frozen role configuration"),
         true <- frozen["schema"] == @schema_version,
         true <- canonical_identity?(frozen["project_identity"]),
         true <- valid_name?(frozen["configuration_name"]),
         true <- frozen["configuration_source"] in ["project", "engine-default"],
         true <- valid_sha256?(frozen["configuration_raw_sha256"]),
         :ok <- validate_frozen_roles(frozen["roles"]),
         true <- valid_sha256?(frozen["effective_fingerprint"]),
         true <-
           fingerprint(Map.delete(frozen, "effective_fingerprint")) ==
             frozen["effective_fingerprint"] do
      :ok
    else
      _ -> {:error, "frozen role configuration is invalid or has been changed"}
    end
  end

  def validate_frozen(_), do: {:error, "frozen role configuration must be a map"}

  @doc "Return a validated frozen profile for one retained role."
  @spec role(map(), String.t() | atom()) :: {:ok, map()} | {:error, String.t()}
  def role(frozen, role_name) when is_atom(role_name), do: role(frozen, Atom.to_string(role_name))

  def role(frozen, role_name) when is_binary(role_name) do
    with :ok <- validate_frozen(frozen),
         true <- role_name in @roles,
         {:ok, profile} <- Map.fetch(frozen["roles"], role_name) do
      {:ok, profile}
    else
      _ -> {:error, "unknown or invalid frozen role"}
    end
  end

  def role(_frozen, _role_name), do: {:error, "unknown or invalid frozen role"}

  def roles, do: @roles

  defp load_configuration(project_identity) do
    case File.lstat(Path.join(project_identity, ".kogen")) do
      {:error, :enoent} -> builtin_source()
      {:ok, %{type: :directory}} -> load_project_configuration(project_identity)
      _ -> {:error, "project .kogen path must be a real directory"}
    end
  end

  defp load_project_configuration(project_identity) do
    relative = [".kogen", "config.yaml"]

    case safe_read(project_identity, relative, @max_config_bytes) do
      {:error, :enoent} ->
        builtin_source()

      {:ok, bytes} ->
        with true <- String.valid?(bytes),
             :ok <- validate_yaml_source(bytes),
             {:ok, document} <- decode_yaml(bytes),
             :ok <-
               exact_keys(
                 document,
                 ~w(runtime default_configuration configurations),
                 "config.yaml"
               ),
             true <- document["runtime"] == "custom",
             {:ok, default_name} <- nonempty_name(document["default_configuration"]),
             {:ok, configurations} <- configuration_map(document["configurations"]),
             true <- Map.has_key?(configurations, default_name),
             :ok <- validate_configuration_names(configurations),
             {:ok, profiles} <- validate_configuration_shape(configurations) do
          {:ok,
           %{
             source: "project",
             raw_sha256: sha256(bytes),
             default_name: default_name,
             profiles: profiles
           }}
        else
          false -> {:error, "config.yaml must contain valid UTF-8"}
          {:error, message} -> {:error, message}
          _ -> {:error, "invalid custom role configuration in .kogen/config.yaml"}
        end

      {:error, reason} ->
        {:error, "cannot read project .kogen/config.yaml: #{format_reason(reason)}"}
    end
  end

  defp builtin_source do
    with {:ok, profiles} <- validate_configuration_shape(%{"default" => @builtin_profiles}) do
      {:ok,
       %{
         source: "engine-default",
         raw_sha256: sha256(<<>>),
         default_name: "default",
         profiles: profiles
       }}
    end
  end

  defp configuration_profiles(%{default_name: default, profiles: profiles}),
    do: {:ok, default, profiles}

  defp select_configuration(default, _profiles, nil), do: {:ok, default}

  defp select_configuration(_default, profiles, requested) when is_binary(requested) do
    if valid_name?(requested) and Map.has_key?(profiles, requested),
      do: {:ok, requested},
      else: {:error, "unknown custom role configuration #{inspect(requested)}"}
  end

  defp select_configuration(_default, _profiles, _requested),
    do: {:error, "configuration name must be a simple lowercase name"}

  defp configuration_map(configurations)
       when is_map(configurations) and map_size(configurations) > 0,
       do: {:ok, configurations}

  defp configuration_map(_), do: {:error, "configurations must be a nonempty map"}

  defp validate_configuration_names(configurations) do
    if Enum.all?(Map.keys(configurations), &valid_name?/1),
      do: :ok,
      else: {:error, "configuration names must be simple lowercase names"}
  end

  defp validate_configuration_shape(configurations) do
    Enum.reduce_while(configurations, {:ok, %{}}, fn {name, profiles}, {:ok, acc} ->
      case validate_role_map(profiles) do
        {:ok, roles} ->
          {:cont, {:ok, Map.put(acc, name, roles)}}

        {:error, _} ->
          {:halt, {:error, "configuration #{name} must define all five retained roles"}}
      end
    end)
  end

  defp validate_role_map(roles) when is_map(roles) do
    with :ok <- exact_keys(roles, @roles, "configuration roles"),
         true <- Enum.all?(@roles, &Map.has_key?(roles, &1)),
         {:ok, normalized} <- normalize_profiles(roles) do
      {:ok, normalized}
    else
      _ -> {:error, "configuration must define all five retained roles"}
    end
  end

  defp validate_role_map(_), do: {:error, "configuration roles must be a map"}

  defp normalize_profiles(roles) do
    Enum.reduce_while(@roles, {:ok, %{}}, fn role, {:ok, acc} ->
      case normalize_profile(role, roles[role]) do
        {:ok, profile} -> {:cont, {:ok, Map.put(acc, role, profile)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_profile(role, profile) when is_map(profile) do
    with :ok <- exact_keys(profile, @frozen_profile_keys, "#{role} profile"),
         true <- Enum.all?(@frozen_profile_keys, &Map.has_key?(profile, &1)),
         true <- valid_model_effort?(profile["model"], profile["effort"]),
         {:ok, prompt} <- prompt_reference(profile["prompt"]),
         {:ok, tools} <- validate_tools(role, profile["tools"]),
         true <- profile["context"] == "full" do
      {:ok,
       %{
         "model" => profile["model"],
         "effort" => profile["effort"],
         "prompt" => prompt,
         "tools" => tools,
         "context" => "full"
       }}
    else
      _ -> {:error, "invalid #{role} profile"}
    end
  end

  defp normalize_profile(_role, _profile), do: {:error, "role profile must be a map"}

  defp prompt_reference(identity) when is_binary(identity) do
    cond do
      identity in @prompt_identities ->
        {:ok, %{kind: "engine", identity: identity, relative: identity <> ".md"}}

      String.starts_with?(identity, "project:") ->
        relative = String.replace_prefix(identity, "project:", "")

        if safe_relative_path?(relative) and Path.extname(relative) == ".md" do
          {:ok, %{kind: "project", identity: identity, relative: relative}}
        else
          {:error, "project prompt must name a safe relative Markdown path"}
        end

      true ->
        {:error, "prompt must be an engine identity or an explicit project: path"}
    end
  end

  defp prompt_reference(_), do: {:error, "prompt identity must be a string"}

  defp validate_tools(role, tools) when is_list(tools) and tools != [] do
    allowed = if role in ["reviewer", "auditor", "expert"], do: @read_only_tools, else: @tools

    if Enum.all?(tools, &(is_binary(&1) and &1 in allowed)) and "read" in tools and
         length(tools) == MapSet.size(MapSet.new(tools)) do
      {:ok, Enum.filter(@tools, &(&1 in tools))}
    else
      {:error, "#{role} tools are unsupported or unsafe"}
    end
  end

  defp validate_tools(_role, _tools), do: {:error, "tools must be a nonempty list"}

  defp valid_model_effort?(model, effort) when is_binary(model) and is_binary(effort),
    do: effort in Map.get(@supported_models, model, [])

  defp valid_model_effort?(_, _), do: false

  defp validate_all_profiles(all_profiles, project_identity, engine_identity) do
    Enum.reduce_while(all_profiles, {:ok, %{}}, fn {name, role_map}, {:ok, acc} ->
      case validate_profile_prompts(role_map, project_identity, engine_identity) do
        {:ok, profiles} ->
          {:cont, {:ok, Map.put(acc, name, profiles)}}

        {:error, _} ->
          {:halt, {:error, "configuration #{name} contains an invalid prompt path or file"}}
      end
    end)
  end

  defp validate_profile_prompts(role_map, project_identity, engine_identity) do
    Enum.reduce_while(@roles, {:ok, %{}}, fn role, {:ok, acc} ->
      profile = role_map[role]
      prompt = profile["prompt"]
      root = if prompt.kind == "engine", do: engine_identity, else: project_identity

      path_parts =
        if prompt.kind == "engine",
          do: ["priv", "kogen", "custom", "prompts", prompt.relative],
          else: String.split(prompt.relative, "/")

      case read_frozen_prompt(root, path_parts, prompt.identity) do
        {:ok, resolved_prompt} ->
          {:cont, {:ok, Map.put(acc, role, Map.put(profile, "prompt", resolved_prompt))}}

        {:error, _reason} ->
          {:halt, {:error, invalid_prompt_message()}}
      end
    end)
  end

  defp read_frozen_prompt(root, path_parts, identity) do
    with {:ok, bytes} <- safe_read(root, path_parts, @max_prompt_bytes),
         {:ok, prompt} <- frozen_prompt(identity, bytes) do
      {:ok, prompt}
    else
      _ -> {:error, :invalid_prompt}
    end
  end

  defp frozen_prompt(identity, bytes) do
    if byte_size(bytes) > 0 and String.valid?(bytes) and not contains_secret?(bytes) do
      {:ok, %{"identity" => identity, "sha256" => sha256(bytes), "bytes" => bytes}}
    else
      :error
    end
  end

  defp invalid_prompt_message,
    do: "prompt bytes are missing, invalid, oversized, or contain a credential"

  defp freeze_roles(profiles) do
    {:ok, Map.take(profiles, @roles)}
  end

  defp validate_frozen_roles(roles) when is_map(roles) do
    with :ok <- exact_keys(roles, @roles, "frozen roles"),
         true <- Enum.all?(@roles, &Map.has_key?(roles, &1)),
         :ok <- validate_frozen_profiles(roles) do
      :ok
    else
      _ -> {:error, "frozen roles are invalid"}
    end
  end

  defp validate_frozen_roles(_), do: {:error, "frozen roles must be a map"}

  defp validate_frozen_profiles(roles) do
    Enum.reduce_while(@roles, :ok, fn role, :ok ->
      case validate_frozen_profile(role, roles[role]) do
        :ok -> {:cont, :ok}
        _ -> {:halt, {:error, "invalid frozen #{role} profile"}}
      end
    end)
  end

  defp validate_frozen_profile(role, profile) when is_map(profile) do
    with :ok <- exact_keys(profile, @frozen_profile_keys, "frozen #{role} profile"),
         true <- Enum.all?(@frozen_profile_keys, &Map.has_key?(profile, &1)),
         true <- valid_model_effort?(profile["model"], profile["effort"]),
         true <- profile["context"] == "full",
         {:ok, tools} <- validate_tools(role, profile["tools"]),
         true <- tools == profile["tools"],
         :ok <- validate_prompt_frozen(profile["prompt"]) do
      :ok
    else
      _ -> {:error, "invalid frozen role profile"}
    end
  end

  defp validate_frozen_profile(_role, _profile), do: {:error, "frozen role profile must be a map"}

  defp validate_prompt_frozen(prompt) when is_map(prompt) do
    with :ok <- exact_keys(prompt, ~w(identity sha256 bytes), "frozen prompt"),
         identity when is_binary(identity) <- prompt["identity"],
         true <- valid_prompt_identity?(identity),
         bytes
         when is_binary(bytes) and byte_size(bytes) > 0 and byte_size(bytes) <= @max_prompt_bytes <-
           prompt["bytes"],
         true <- String.valid?(bytes),
         true <- not contains_secret?(bytes),
         true <- valid_sha256?(prompt["sha256"]),
         true <- sha256(bytes) == prompt["sha256"] do
      :ok
    else
      _ -> {:error, "frozen prompt bytes or digest are invalid"}
    end
  end

  defp validate_prompt_frozen(_), do: {:error, "frozen prompt must be a map"}

  defp valid_prompt_identity?(identity) when identity in @prompt_identities, do: true

  defp valid_prompt_identity?("project:" <> relative),
    do: safe_relative_path?(relative) and Path.extname(relative) == ".md"

  defp valid_prompt_identity?(_), do: false

  defp decode_yaml(bytes) do
    case YamlElixir.read_from_string(bytes) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> {:error, "YAML document must be a map"}
    end
  rescue
    _ -> {:error, "YAML document is malformed"}
  end

  defp validate_yaml_source(bytes) do
    cond do
      contains_secret?(bytes) ->
        {:error, "config.yaml contains a credential or secret field"}

      supported_yaml_source?(bytes) ->
        :ok

      true ->
        {:error, "config.yaml does not match the supported block-mapping grammar"}
    end
  end

  defp supported_yaml_source?(bytes) do
    initial = %{top: nil, configuration: nil, role: nil, seen: MapSet.new()}

    result =
      bytes
      |> String.split("\n")
      |> Enum.reduce_while({:ok, initial}, fn raw_line, {:ok, state} ->
        case validate_source_line(raw_line, state) do
          {:ok, next} -> {:cont, {:ok, next}}
          :invalid -> {:halt, :invalid}
        end
      end)

    match?({:ok, _state}, result)
  end

  defp validate_source_line(raw_line, state) do
    case strip_yaml_comment(raw_line) do
      {:ok, visible} -> validate_visible_source_line(visible, state)
      _ -> :invalid
    end
  end

  defp validate_visible_source_line(visible, state) do
    case String.trim_trailing(visible) do
      "" -> {:ok, state}
      line -> validate_source_mapping_line(line, state)
    end
  end

  defp validate_source_mapping_line(line, state) do
    with {:ok, indent, key, value} <- source_mapping_entry(line),
         {:ok, next} <- validate_source_mapping_entry(state, indent, key, value) do
      {:ok, next}
    else
      _ -> :invalid
    end
  end

  defp source_mapping_entry(line) do
    case Regex.run(@yaml_mapping_line, line, capture: :all_but_first) do
      [indent, key, raw_value] ->
        value = String.trim(raw_value)

        if raw_value == "" or String.starts_with?(raw_value, [" ", "\t"]),
          do: {:ok, byte_size(indent), key, value},
          else: {:error, :missing_key_separator}

      _ ->
        {:error, :unsupported_mapping_line}
    end
  end

  defp validate_source_mapping_entry(state, 0, key, value)
       when key in ["runtime", "default_configuration", "configurations"] do
    value_valid? = if key == "configurations", do: value == "", else: source_scalar?(value)

    with true <- value_valid?,
         {:ok, state} <- mark_source_key(state, [key]) do
      {:ok, %{state | top: key, configuration: nil, role: nil}}
    else
      _ -> {:error, :invalid_top_level_entry}
    end
  end

  defp validate_source_mapping_entry(%{top: "configurations"} = state, 2, key, "") do
    with true <- valid_name?(key),
         {:ok, state} <- mark_source_key(state, ["configurations", key]) do
      {:ok, %{state | configuration: key, role: nil}}
    else
      _ -> {:error, :invalid_configuration_entry}
    end
  end

  defp validate_source_mapping_entry(
         %{top: "configurations", configuration: config} = state,
         4,
         role,
         ""
       )
       when is_binary(config) and role in @roles do
    with {:ok, state} <- mark_source_key(state, ["configurations", config, role]) do
      {:ok, %{state | role: role}}
    end
  end

  defp validate_source_mapping_entry(
         %{top: "configurations", configuration: config, role: role} = state,
         6,
         key,
         value
       )
       when is_binary(config) and is_binary(role) and key in @frozen_profile_keys do
    valid_value? = if key == "tools", do: tools_source_value?(value), else: source_scalar?(value)

    with true <- valid_value?,
         {:ok, state} <- mark_source_key(state, ["configurations", config, role, key]) do
      {:ok, state}
    else
      _ -> {:error, :invalid_profile_entry}
    end
  end

  defp validate_source_mapping_entry(_state, _indent, _key, _value),
    do: {:error, :unsupported_indentation_or_mapping}

  defp mark_source_key(state, path) do
    key = Enum.join(path, <<0>>)

    if MapSet.member?(state.seen, key),
      do: {:error, :duplicate_mapping_key},
      else: {:ok, %{state | seen: MapSet.put(state.seen, key)}}
  end

  defp source_scalar?(value) do
    value != "" and
      (Regex.match?(@yaml_plain_scalar, value) or Regex.match?(@yaml_double_scalar, value) or
         Regex.match?(@yaml_single_scalar, value))
  end

  defp tools_source_value?(value), do: Regex.match?(@yaml_tools_sequence, value)

  defp strip_yaml_comment(line),
    do: strip_yaml_comment(String.to_charlist(line), nil, false, true, [])

  defp strip_yaml_comment([], nil, _escaped?, _previous_space?, acc),
    do: {:ok, acc |> Enum.reverse() |> List.to_string()}

  defp strip_yaml_comment([], _quote, _escaped?, _previous_space?, _acc),
    do: {:error, :unterminated_quoted_scalar}

  defp strip_yaml_comment([?\', ?\' | rest], :single, _escaped?, _previous_space?, acc),
    do: strip_yaml_comment(rest, :single, false, false, [?\', ?\' | acc])

  defp strip_yaml_comment([?\' | rest], :single, _escaped?, _previous_space?, acc),
    do: strip_yaml_comment(rest, nil, false, false, [?\' | acc])

  defp strip_yaml_comment([?\\ | rest], :double, false, _previous_space?, acc),
    do: strip_yaml_comment(rest, :double, true, false, [?\\ | acc])

  defp strip_yaml_comment([char | rest], :double, true, _previous_space?, acc),
    do: strip_yaml_comment(rest, :double, false, false, [char | acc])

  defp strip_yaml_comment([?" | rest], :double, false, _previous_space?, acc),
    do: strip_yaml_comment(rest, nil, false, false, [?" | acc])

  defp strip_yaml_comment([char | rest], quote, escaped?, _previous_space?, acc)
       when quote in [:single, :double],
       do: strip_yaml_comment(rest, quote, escaped?, false, [char | acc])

  defp strip_yaml_comment([?# | _rest], nil, _escaped?, true, acc),
    do: {:ok, acc |> Enum.reverse() |> List.to_string()}

  defp strip_yaml_comment([?" | rest], nil, _escaped?, _previous_space?, acc),
    do: strip_yaml_comment(rest, :double, false, false, [?" | acc])

  defp strip_yaml_comment([?\' | rest], nil, _escaped?, _previous_space?, acc),
    do: strip_yaml_comment(rest, :single, false, false, [?\' | acc])

  defp strip_yaml_comment([char | rest], nil, _escaped?, _previous_space?, acc),
    do: strip_yaml_comment(rest, nil, false, char in [32, 9], [char | acc])

  defp exact_keys(map, allowed, label) when is_map(map) do
    keys = Map.keys(map)

    if Enum.all?(keys, &(is_binary(&1) and &1 in allowed)),
      do: :ok,
      else: {:error, "#{label} has unknown keys"}
  end

  defp nonempty_name(name) when is_binary(name) do
    if valid_name?(name), do: {:ok, name}, else: {:error, "invalid configuration name"}
  end

  defp nonempty_name(_), do: {:error, "default_configuration must be a name"}

  defp valid_name?(name), do: is_binary(name) and Regex.match?(@name, name)

  defp safe_relative_path?(path) when is_binary(path) and path != "" do
    Path.type(path) == :relative and not String.contains?(path, "\\") and
      not String.contains?(path, <<0>>) and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))
  end

  defp safe_relative_path?(_), do: false

  defp canonical_identity?(identity) when is_binary(identity) do
    Path.type(identity) == :absolute and Path.expand(identity) == identity and
      not String.contains?(identity, <<0>>) and
      Enum.all?(String.split(identity, "/"), &(&1 != ".."))
  end

  defp canonical_identity?(_), do: false

  defp valid_sha256?(value), do: is_binary(value) and Regex.match?(@sha256, value)

  defp contains_secret?(bytes), do: Enum.any?(@secret_patterns, &Regex.match?(&1, bytes))

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp fingerprint(frozen) do
    frozen
    |> canonical_json()
    |> sha256()
  end

  defp canonical_json(value) when is_map(value) do
    entries =
      value
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.map(fn {key, nested} -> Jason.encode!(key) <> ":" <> canonical_value(nested) end)

    "{" <> Enum.join(entries, ",") <> "}"
  end

  defp canonical_value(value) when is_map(value) do
    entries =
      value
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.map(fn {key, nested} -> Jason.encode!(key) <> ":" <> canonical_value(nested) end)

    "{" <> Enum.join(entries, ",") <> "}"
  end

  defp canonical_value(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &canonical_value/1) <> "]"

  defp canonical_value(value), do: Jason.encode!(value)

  defp canonical_directory(path, label) when is_binary(path) and path != "" do
    with false <- String.contains?(path, <<0>>),
         false <- Enum.any?(String.split(path, "/"), &(&1 == "..")),
         absolute = Path.expand(path),
         {:ok, canonical} <- resolve_components("/", path_components(absolute), 0),
         {:ok, %{type: :directory}} <- File.lstat(canonical) do
      {:ok, canonical}
    else
      _ -> {:error, "#{label} must be an existing directory with a valid path"}
    end
  end

  defp canonical_directory(_path, label), do: {:error, "#{label} must be an existing directory"}

  defp path_components(path), do: String.split(path, "/", trim: true)

  defp resolve_components(_current, _components, depth) when depth > 40,
    do: {:error, :too_many_symlinks}

  defp resolve_components(current, [], _depth), do: {:ok, current}

  defp resolve_components(current, ["." | rest], depth),
    do: resolve_components(current, rest, depth)

  defp resolve_components(current, [".." | rest], depth),
    do: resolve_components(Path.dirname(current), rest, depth)

  defp resolve_components(current, [component | rest], depth) do
    next = Path.join(current, component)

    case File.lstat(next) do
      {:ok, %{type: :symlink}} ->
        follow_link(next, current, rest, depth)

      {:ok, _info} ->
        resolve_components(next, rest, depth)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp follow_link(path, current, rest, depth) do
    case File.read_link(path) do
      {:ok, target} ->
        target_root = if Path.type(target) == :absolute, do: "/", else: current
        target_components = String.split(target, "/", trim: true)
        resolve_components(target_root, target_components ++ rest, depth + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp safe_read(root, components, max_bytes) do
    with true <- components != [] and Enum.all?(components, &safe_component?/1),
         {:ok, path, before} <- inspect_path(root, components),
         true <- before.size <= max_bytes,
         {:ok, bytes} <- File.read(path),
         {:ok, after_info} <- File.lstat(path),
         true <- stable_file?(before, after_info),
         true <- byte_size(bytes) <= max_bytes do
      {:ok, bytes}
    else
      false -> {:error, :invalid_or_oversized}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :changed_during_read}
    end
  end

  defp inspect_path(root, components) do
    last_index = length(components) - 1

    components
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, root, nil}, fn {component, index}, {:ok, parent, _last} ->
      path = Path.join(parent, component)
      final? = index == last_index

      case File.lstat(path) do
        {:ok, %{type: :symlink}} ->
          {:halt, {:error, :symlink}}

        {:ok, %{type: type} = info} when type in [:directory, :regular] ->
          inspect_component(path, info, type, final?)

        {:ok, _} ->
          {:halt, {:error, :not_regular}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp inspect_component(_path, _info, :directory, true),
    do: {:halt, {:error, :not_regular}}

  defp inspect_component(_path, _info, :regular, false), do: {:halt, {:error, :not_directory}}
  defp inspect_component(path, info, _type, _final?), do: {:cont, {:ok, path, info}}

  defp stable_file?(before, after_info) do
    fields = [:type, :size, :inode, :major_device, :minor_device, :mtime, :ctime]
    Map.take(before, fields) == Map.take(after_info, fields) and after_info.type == :regular
  end

  defp safe_component?(component),
    do:
      is_binary(component) and component not in ["", ".", ".."] and
        not String.contains?(component, ["/", "\\", <<0>>])

  defp format_reason(:symlink), do: "symbolic links are not allowed"
  defp format_reason(_), do: "path is not a regular file"
end

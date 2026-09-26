defmodule Kogen.Intent do
  use Boundary, deps: []

  @moduledoc """
  Reads and validates the tracked `.kogen/config.yaml` and per-slug
  `intent.yaml` files, and mints RFC 9562 UUIDv7 identifiers.

  This is a leaf compartment: it reads YAML off disk (via `YamlElixir`)
  and depends on nothing else in the application.
  """

  @default_config_path ".kogen/config.yaml"
  @harnesses ["codex", "claude"]
  @claude_models Path.expand("../../priv/kogen/claude_code/models.yaml", __DIR__)
  @claude_roles [
    {"shaping", [:shaping]},
    {"developer", [:developer]},
    {"reviewer", [:reviewer]},
    {"helpers.scout", [:helpers, :scout]},
    {"helpers.worker", [:helpers, :worker]},
    {"helpers.expert", [:helpers, :expert]}
  ]
  # The role-to-harness matrix, in launch-readiness order. The Expert is a
  # role: in a clean route it is the route's native expert helper; in a
  # role-level route it may run on another harness than the role consulting it.
  @roles [:shaping, :developer, :reviewer, :expert]
  @native_helpers [:scout, :worker]

  @type role_config :: %{model: String.t(), effort: String.t()}
  @type role :: :shaping | :developer | :reviewer | :expert

  @type config :: %{
          route: String.t(),
          harness: String.t(),
          shaping: role_config(),
          developer: role_config(),
          reviewer: role_config(),
          expert: role_config(),
          helpers: %{
            required(:scout) => role_config(),
            required(:worker) => role_config(),
            optional(:expert) => role_config()
          },
          roles: %{required(role()) => String.t()},
          native_helpers: %{
            required(String.t()) => %{scout: role_config(), worker: role_config()}
          },
          outer_resumptions: non_neg_integer(),
          verification_retries: non_neg_integer()
        }

  @type intent :: %{
          id: String.t(),
          slug: String.t(),
          title: String.t(),
          may_change_guarded_paths: [String.t()],
          catalog_changes: %{add: [String.t()]},
          raw: map()
        }

  @doc """
  Reads the tracked Kogen configuration and resolves one named route.

  `route` names the route to select; `nil` selects the configured
  `default_route`, the only default. Every route is checked for structure and
  no key has a default. Harness support and Claude Code proven models are
  checked only for the selected route. The old flat shape is refused.

  A route is either clean, naming one top-level `harness` for every role and
  its `helpers`, or role-level, naming a `harness`, `model` and `effort` for
  each of `shaping`, `developer`, `reviewer` and `expert`, with `helpers`
  (`scout` and `worker`) keyed by every harness a role uses. Helpers stay
  native to the harness of the role that launches them.

  On success returns `{:ok, config}`: the selected route's dominant `harness`
  (the Developer's), role and helper profiles, `expert`, the role-to-harness
  matrix `roles`, each harness's `native_helpers`, the global retry policy,
  and `route` (the selected name), with atom keys regardless of whether the
  YAML parser produced string or atom keys. `helpers` is the dominant
  harness's native helper set (see `harness_config/2`).
  """
  @spec read_config(Path.t(), String.t() | nil) :: {:ok, config()} | {:error, String.t()}
  def read_config(path \\ @default_config_path, route \\ nil) do
    with {:ok, data} <- load_yaml(path, "missing #{path}"),
         :ok <- routes_shape(data),
         {:ok, routes} <- normalize_routes(data),
         {:ok, default_route} <- default_route(data, routes),
         {:ok, outer_resumptions} <- config_integer(data, "outer_resumptions"),
         {:ok, verification_retries} <- config_integer(data, "verification_retries"),
         {:ok, name} <- select_route(routes, route || default_route),
         selected = Map.fetch!(routes, name),
         :ok <- supported_harnesses(selected),
         :ok <- proven_models(selected) do
      {:ok,
       Map.merge(selected, %{
         route: name,
         outer_resumptions: outer_resumptions,
         verification_retries: verification_retries
       })}
    end
  end

  @flat_config_error "config.yaml uses the replaced flat configuration shape (top-level harness and roles); define default_route and routes instead"

  defp routes_shape(data) do
    flat? =
      (has_key?(data, "harness") and not has_key?(data, "routes")) or
        not (has_key?(data, "default_route") or has_key?(data, "routes"))

    if flat?, do: {:error, @flat_config_error}, else: :ok
  end

  defp has_key?(map, key), do: match?({:ok, _value}, fetch(map, key))

  # Every route is structurally validated, in name order, whether or not it is
  # selected; a broken unselected route is a configuration error.
  defp normalize_routes(data) do
    case fetch(data, "routes") do
      {:ok, routes} when is_map(routes) and map_size(routes) > 0 ->
        routes
        |> Enum.sort_by(fn {name, _route} -> to_string(name) end)
        |> Enum.reduce_while({:ok, %{}}, &collect_route/2)

      _ ->
        {:error, "config.yaml missing required key: routes"}
    end
  end

  defp collect_route({name, route}, {:ok, acc}) do
    case normalize_route(name, route) do
      {:ok, resolved} -> {:cont, {:ok, Map.put(acc, to_string(name), resolved)}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp normalize_route(name, route) when is_binary(name) and is_map(route) do
    with :ok <- route_name(name),
         {:ok, resolved} <- normalize_route_body(route) do
      {:ok, resolved}
    else
      {:error, "config.yaml " <> _reason} = error -> error
      {:error, {:refused, key, reason}} -> {:error, "config.yaml routes.#{name}.#{key} #{reason}"}
      {:error, key} -> {:error, "config.yaml missing required key: routes.#{name}.#{key}"}
    end
  end

  defp normalize_route(name, _route) when is_binary(name),
    do: {:error, "config.yaml missing required key: routes.#{name}"}

  defp normalize_route(name, _route),
    do: {:error, "config.yaml route names must be nonblank strings: #{inspect(name)}"}

  # A route with no harness anywhere is a clean route missing its harness.
  defp normalize_route_body(route) do
    role_level? =
      not has_key?(route, "harness") and
        Enum.any?(@roles, fn role ->
          match?({:ok, %{} = sub} when is_map_key(sub, "harness"), fetch(route, "#{role}")) or
            match?({:ok, %{harness: _}}, fetch(route, "#{role}"))
        end)

    if role_level?,
      do: normalize_role_route(route),
      else: normalize_clean_route(route)
  end

  # One harness for every role; the configured expert helper is the Expert, so
  # clean routes need no new keys.
  defp normalize_clean_route(route) do
    with {:ok, harness} <- require_string(route, "harness", "harness"),
         :ok <- no_role_harness(route),
         {:ok, shaping} <- require_role(route, "shaping"),
         {:ok, developer} <- require_role(route, "developer"),
         {:ok, reviewer} <- require_role(route, "reviewer"),
         {:ok, helpers} <- require_helpers(route) do
      {:ok,
       %{
         harness: harness,
         shaping: shaping,
         developer: developer,
         reviewer: reviewer,
         expert: helpers.expert,
         helpers: helpers,
         roles: Map.new(@roles, &{&1, harness}),
         native_helpers: %{harness => Map.take(helpers, @native_helpers)}
       }}
    end
  end

  # A clean route's single harness is the only one; a role-level harness beside
  # it would be silently ignored, so it is refused.
  defp no_role_harness(route) do
    Enum.find_value(~w(shaping developer reviewer expert), :ok, fn role ->
      with {:ok, sub} when is_map(sub) <- fetch(route, role),
           true <- has_key?(sub, "harness") do
        {:error, {:refused, "#{role}.harness", "is not allowed beside a route-level harness"}}
      else
        _ -> nil
      end
    end)
  end

  # Every role names its own harness; no role inherits a dominant harness.
  defp normalize_role_route(route) do
    with {:ok, assigned} <- require_assigned_roles(route),
         roles = Map.new(assigned, fn {role, harness, _profile} -> {role, harness} end),
         {:ok, native_helpers} <- require_native_helpers(route, roles) do
      config =
        assigned
        |> Map.new(fn {role, _harness, profile} -> {role, profile} end)
        |> Map.merge(%{harness: roles.developer, roles: roles, native_helpers: native_helpers})

      {:ok, Map.put(config, :helpers, native_helper_set(config, roles.developer))}
    end
  end

  defp require_assigned_roles(route) do
    Enum.reduce_while(@roles, {:ok, []}, fn role, {:ok, acc} ->
      name = Atom.to_string(role)

      with {:ok, sub} when is_map(sub) <- fetch(route, name),
           {:ok, harness} <- require_string(sub, "harness", "#{name}.harness"),
           {:ok, profile} <- require_role(route, name) do
        {:cont, {:ok, acc ++ [{role, harness, profile}]}}
      else
        {:error, key} -> {:halt, {:error, key}}
        _ -> {:halt, {:error, name}}
      end
    end)
  end

  defp require_native_helpers(route, roles) do
    case fetch(route, "helpers") do
      {:ok, helpers} when is_map(helpers) ->
        roles
        |> Map.values()
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.reduce_while({:ok, %{}}, &collect_native_helpers(&1, &2, helpers))

      _ ->
        {:error, "helpers"}
    end
  end

  defp collect_native_helpers(harness, {:ok, acc}, helpers) do
    with {:ok, set} when is_map(set) <- fetch(helpers, harness),
         :ok <- no_native_expert(set, harness),
         {:ok, scout} <- require_role(set, "scout"),
         {:ok, worker} <- require_role(set, "worker") do
      {:cont, {:ok, Map.put(acc, harness, %{scout: scout, worker: worker})}}
    else
      {:error, {:refused, _key, _reason}} = error -> {:halt, error}
      {:error, key} -> {:halt, {:error, "helpers.#{harness}.#{key}"}}
      _ -> {:halt, {:error, "helpers.#{harness}"}}
    end
  end

  defp no_native_expert(set, harness) do
    if has_key?(set, "expert"),
      do:
        {:error,
         {:refused, "helpers.#{harness}.expert",
          "is not allowed in a role-level route; assign the expert role instead"}},
      else: :ok
  end

  @doc """
  The native configuration of one harness in a resolved route: `harness` set
  to it and `helpers` holding that harness's native scout and worker, plus the
  native expert only when the route assigns the Expert role to that harness.
  Adapters launch every role of that harness from this view.
  """
  @spec harness_config(map(), String.t()) :: map()
  def harness_config(%{native_helpers: native} = config, harness)
      when is_map_key(native, harness),
      do: %{config | harness: harness, helpers: native_helper_set(config, harness)}

  # A harness without native helpers is never replaced by another harness; the
  # adapter dispatch refuses it.
  def harness_config(%{native_helpers: _native} = config, harness),
    do: %{config | harness: harness}

  def harness_config(config, _harness), do: config

  @doc "The resolved route viewed from one role: its assigned harness's native configuration."
  @spec role_config(map(), role()) :: map()
  def role_config(config, role), do: harness_config(config, role_harness(config, role))

  @doc """
  The harness assigned to `role`; a route without a role matrix uses its one
  harness. Only the route's roles resolve; any other role raises.
  """
  @spec role_harness(map(), role()) :: String.t()
  def role_harness(_config, role) when role not in @roles,
    do: raise(ArgumentError, "unknown role #{inspect(role)}")

  def role_harness(%{roles: roles}, role) when is_map_key(roles, role),
    do: Map.fetch!(roles, role)

  def role_harness(config, _role), do: Map.fetch!(config, :harness)

  @doc "The route's roles in launch-readiness order."
  def roles, do: @roles

  defp native_helper_set(config, harness) do
    native = Map.fetch!(config.native_helpers, harness)

    if config.roles.expert == harness,
      do: Map.put(native, :expert, config.expert),
      else: native
  end

  defp route_name(name) do
    if String.trim(name) == "",
      do: {:error, "config.yaml route names must be nonblank strings: #{inspect(name)}"},
      else: :ok
  end

  defp default_route(data, routes) do
    case require_string(data, "default_route", "default_route") do
      {:ok, name} when is_map_key(routes, name) ->
        {:ok, name}

      {:ok, name} ->
        {:error,
         "config.yaml default_route names unknown route: #{name}; available routes: #{route_names(routes)}"}

      {:error, key} ->
        {:error, "config.yaml missing required key: #{key}"}
    end
  end

  defp config_integer(data, key) do
    case require_integer(data, key) do
      {:ok, value} -> {:ok, value}
      {:error, key} -> {:error, "config.yaml missing required key: #{key}"}
    end
  end

  defp select_route(routes, name) when is_map_key(routes, name), do: {:ok, name}

  defp select_route(routes, name),
    do: {:error, "unknown route: #{name}; available routes: #{route_names(routes)}"}

  defp route_names(routes), do: routes |> Map.keys() |> Enum.sort() |> Enum.join(", ")

  @doc """
  Reads the proven Claude Code model picker. Each entry names a model, the
  efforts Kogen may configure for it, and the retained evidence proving it.
  """
  @spec claude_models(Path.t()) :: {:ok, [map()]} | {:error, String.t()}
  def claude_models(path \\ @claude_models) do
    with {:ok, data} <- load_yaml(path, "missing proven Claude Code model list: #{path}"),
         {:ok, models} when is_list(models) and models != [] <- fetch(data, "models"),
         true <- Enum.all?(models, &valid_model_entry?/1) do
      {:ok, models}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _ -> {:error, "invalid proven Claude Code model list: #{path}"}
    end
  end

  defp valid_model_entry?(%{"id" => id, "efforts" => efforts, "evidence" => evidence})
       when is_binary(id) and is_list(efforts) and efforts != [] and is_binary(evidence) do
    String.trim(id) != "" and String.trim(evidence) != "" and Enum.all?(efforts, &is_binary/1)
  end

  defp valid_model_entry?(_entry), do: false

  # Codex model routing is unchanged. Claude Code roles may select only a model
  # and effort from the proven picker; Kogen never widens it per request. Only
  # the selected route is checked, so an unselected route may name an unproven
  # model without blocking sessions on other routes. In a role-level route only
  # the roles and native helpers assigned to Claude Code are checked.
  defp proven_models(config) do
    case claude_profiles(config) do
      [] -> :ok
      profiles -> with {:ok, models} <- claude_models(), do: proven_profiles(profiles, models)
    end
  end

  defp proven_profiles(profiles, models) do
    proven = Map.new(models, &{&1["id"], &1["efforts"]})

    Enum.find_value(profiles, :ok, fn {label, profile} ->
      proven_profile(label, profile, proven, models)
    end)
  end

  defp claude_profiles(config) do
    cond do
      role_level?(config) ->
        roles =
          for role <- @roles,
              config.roles[role] == "claude",
              do: {Atom.to_string(role), Map.fetch!(config, role)}

        helpers =
          for {"claude", set} <- config.native_helpers,
              label <- @native_helpers,
              do: {"helpers.claude.#{label}", Map.fetch!(set, label)}

        roles ++ helpers

      config.harness == "claude" ->
        Enum.map(@claude_roles, fn {label, keys} -> {label, get_in(config, keys)} end)

      true ->
        []
    end
  end

  # A clean route resolves every role to its one harness and keeps its
  # configured expert helper; anything else was configured role by role.
  defp role_level?(%{roles: roles, harness: harness, native_helpers: native}),
    do: Enum.any?(roles, fn {_role, assigned} -> assigned != harness end) or map_size(native) > 1

  defp proven_profile(label, %{model: model, effort: effort}, proven, models) do
    case Map.fetch(proven, model) do
      {:ok, efforts} ->
        unless effort in efforts do
          {:error,
           "unsupported Claude Code effort for #{label}: #{model} at #{effort}; proven efforts: #{Enum.join(efforts, ", ")}"}
        end

      :error ->
        {:error,
         "unsupported Claude Code model for #{label}: #{model}; proven models: #{Enum.map_join(models, ", ", & &1["id"])}"}
    end
  end

  @doc """
  Reads `<base_dir>/<slug>/intent.yaml` and validates that `id`, `title`,
  and `may_change_guarded_paths` are all present and non-empty.

  Returns `{:ok, intent}` on success, where `raw` is the full parsed map.
  Returns `{:error, reason}` with a short, specific one-line reason
  otherwise (file missing/unreadable, or naming the absent key) suitable
  for use verbatim as a precondition failure message.
  """
  @spec read(String.t(), Path.t()) :: {:ok, intent()} | {:error, String.t()}
  def read(slug, base_dir) do
    path = Path.join([base_dir, slug, "intent.yaml"])

    with :ok <- valid_slug(slug),
         {:ok, data} <- load_yaml(path, "intent.yaml missing: #{path}") do
      normalize_intent(data, slug)
    end
  end

  @doc "Reads only the identity and original provenance needed to continue an unfinished draft."
  def read_draft(slug) do
    path = Path.join([".kogen/intents/drafts", slug, "intent.yaml"])

    with :ok <- valid_slug(slug),
         :ok <- draft_path_safe(slug),
         {:ok, data} <- load_yaml(path, "draft intent.yaml missing or unreadable: #{path}"),
         {:ok, id} <- require_string(data, "id", "id"),
         {:ok, ^slug} <- require_string(data, "slug", "slug"),
         {:ok, baseline} <- require_fields(data, "shaped_against", ~w(branch head)),
         {:ok, shaping} <- require_fields(data, "shaping", ~w(harness model effort started)) do
      {:ok, %{id: id, slug: slug, baseline: baseline, shaping: shaping}}
    else
      {:ok, _other_slug} ->
        {:error, "draft intent.yaml slug does not match selected slug: #{slug}"}

      {:error, reason} ->
        {:error, "cannot continue draft: #{reason}"}
    end
  end

  defp draft_path_safe(slug) do
    paths = [
      ".kogen",
      ".kogen/intents",
      ".kogen/intents/drafts",
      ".kogen/intents/drafts/#{slug}",
      ".kogen/intents/drafts/#{slug}/intent.yaml"
    ]

    if Enum.any?(paths, &match?({:ok, %{type: :symlink}}, File.lstat(&1))),
      do: {:error, "draft selection must not follow symbolic links"},
      else: :ok
  end

  defp require_fields(data, key, fields) do
    case fetch(data, key) do
      {:ok, sub} when is_map(sub) ->
        Enum.reduce_while(fields, {:ok, %{}}, &collect_field(&1, &2, sub, key))

      _ ->
        {:error, "intent.yaml missing required key: #{key}"}
    end
  end

  defp collect_field(field, {:ok, acc}, sub, key) do
    case require_string(sub, field, "#{key}.#{field}") do
      {:ok, value} -> {:cont, {:ok, Map.put(acc, field, value)}}
      {:error, label} -> {:halt, {:error, "intent.yaml missing required key: #{label}"}}
    end
  end

  @doc """
  Mints a UUIDv7 (RFC 9562 section 5.7): a 48-bit big-endian millisecond
  Unix timestamp, a 4-bit version nibble (`0111`), 12 random bits, a 2-bit
  variant (`10`), and 62 more random bits, rendered as the standard
  8-4-4-4-12 lowercase hex string.
  """
  @spec mint_uuid7() :: String.t()
  def mint_uuid7 do
    ts = System.system_time(:millisecond)
    <<rand_a::12, rand_b::62, _discard::6>> = :crypto.strong_rand_bytes(10)

    <<as_int::128>> =
      <<ts::big-unsigned-integer-size(48), 0x7::4, rand_a::12, 0b10::2, rand_b::62>>

    format_uuid(as_int)
  end

  defp format_uuid(as_int) do
    hex =
      as_int
      |> Integer.to_string(16)
      |> String.downcase()
      |> String.pad_leading(32, "0")

    [a, b, c, d, e] =
      for {start, len} <- [{0, 8}, {8, 4}, {12, 4}, {16, 4}, {20, 12}],
          do: binary_part(hex, start, len)

    "#{a}-#{b}-#{c}-#{d}-#{e}"
  end

  defp load_yaml(path, not_found_message) do
    case YamlElixir.read_from_file(path) do
      {:ok, data} when is_map(data) ->
        {:ok, data}

      {:ok, _other} ->
        {:error, not_found_message}

      {:error, %YamlElixir.FileNotFoundError{}} ->
        {:error, not_found_message}

      {:error, error} ->
        {:error, "invalid YAML at #{path}: #{Exception.message(error)}"}
    end
  end

  @doc "Harness names Kogen supports, in documentation order."
  def harnesses, do: @harnesses

  # A role-level route names the role whose harness is unsupported.
  defp supported_harnesses(config) do
    if role_level?(config) do
      case Enum.find(@roles, &(config.roles[&1] not in @harnesses)) do
        nil -> :ok
        role -> supported_harness(config.roles[role], " for #{role}")
      end
    else
      supported_harness(config.harness, "")
    end
  end

  defp supported_harness(name, _label) when name in @harnesses, do: :ok

  defp supported_harness(name, label),
    do:
      {:error, "unsupported harness#{label}: #{name}; expected #{Enum.join(@harnesses, " or ")}"}

  defp normalize_intent(data, slug) do
    with {:ok, id} <- require_string(data, "id", "id"),
         {:ok, title} <- require_string(data, "title", "title"),
         {:ok, guarded} <- require_nonempty_list(data, "may_change_guarded_paths"),
         {:ok, ^slug} <- require_string(data, "slug", "slug"),
         {:ok, changes} <- catalog_changes(data) do
      {:ok,
       %{
         id: id,
         slug: slug,
         title: title,
         may_change_guarded_paths: guarded,
         catalog_changes: changes,
         raw: data
       }}
    else
      {:error, {:invalid, reason}} -> {:error, "intent.yaml #{reason}"}
      {:error, missing_key} -> {:error, "intent.yaml missing required key: #{missing_key}"}
      {:ok, _other_slug} -> {:error, "intent.yaml slug does not match selected slug: #{slug}"}
    end
  end

  @doc """
  The Intent's declared verification-target catalog changes. Only `add` is
  supported: a list of new, safe Make target names the Intent may add to the
  catalog and select in `verified_by`. Absent means no additions.
  """
  @spec catalog_changes(map()) :: {:ok, %{add: [String.t()]}} | {:error, {:invalid, String.t()}}
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def catalog_changes(data) when is_map(data) do
    case fetch(data, "catalog_changes") do
      :error ->
        {:ok, %{add: []}}

      {:ok, changes} when is_map(changes) ->
        keys = changes |> Map.keys() |> Enum.map(&to_string/1)

        add =
          case fetch(changes, "add") do
            {:ok, value} -> value
            :error -> []
          end

        cond do
          keys -- ["add"] != [] ->
            {:error, {:invalid, "catalog_changes supports only add"}}

          not (is_list(add) and Enum.all?(add, &safe_target_name?/1)) ->
            {:error, {:invalid, "catalog_changes.add must list safe Make target names"}}

          Enum.uniq(add) != add ->
            {:error, {:invalid, "catalog_changes.add lists a target twice"}}

          true ->
            {:ok, %{add: add}}
        end

      {:ok, _other} ->
        {:error, {:invalid, "catalog_changes must be a mapping"}}
    end
  end

  def catalog_changes(_data), do: {:ok, %{add: []}}

  defp safe_target_name?(name),
    do: is_binary(name) and Regex.match?(~r/^[a-z][a-z0-9_-]*$/, name)

  defp require_role(data, role) do
    case fetch(data, role) do
      {:ok, sub} when is_map(sub) ->
        with {:ok, model} <- require_string(sub, "model", "#{role}.model"),
             {:ok, effort} <- require_string(sub, "effort", "#{role}.effort") do
          {:ok, %{model: model, effort: effort}}
        end

      _ ->
        {:error, role}
    end
  end

  defp require_helpers(data) do
    with {:ok, helpers} when is_map(helpers) <- fetch(data, "helpers"),
         {:ok, scout} <- require_role(helpers, "scout"),
         {:ok, worker} <- require_role(helpers, "worker"),
         {:ok, expert} <- require_role(helpers, "expert") do
      {:ok, %{scout: scout, worker: worker, expert: expert}}
    else
      {:error, key} -> {:error, "helpers.#{key}"}
      _ -> {:error, "helpers"}
    end
  end

  defp require_string(map, key, label) do
    case fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        if String.trim(value) == "", do: {:error, label}, else: {:ok, value}

      _ ->
        {:error, label}
    end
  end

  defp require_integer(map, key) do
    case fetch(map, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      _ -> {:error, key}
    end
  end

  defp valid_slug(slug) do
    if Regex.match?(~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/, slug),
      do: :ok,
      else: {:error, "invalid Intent slug: #{inspect(slug)}"}
  end

  defp require_nonempty_list(map, key) do
    case fetch(map, key) do
      {:ok, list} when is_list(list) and list != [] ->
        if Enum.all?(list, &(is_binary(&1) and String.trim(&1) != "")),
          do: {:ok, list},
          else: {:error, key}

      _ ->
        {:error, key}
    end
  end

  # `yaml_elixir` returns string keys by default. Tolerate atom keys too,
  # so callers that construct maps by hand (tests, future callers) are
  # not tripped up by this quirk.
  defp fetch(map, key) when is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> fetch_atom(map, key)
    end
  end

  defp fetch_atom(map, key) do
    Map.fetch(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> :error
  end
end

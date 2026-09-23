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

  @type role_config :: %{model: String.t(), effort: String.t()}

  @type config :: %{
          route: String.t(),
          harness: String.t(),
          shaping: role_config(),
          developer: role_config(),
          reviewer: role_config(),
          helpers: %{
            scout: role_config(),
            worker: role_config(),
            expert: role_config()
          },
          outer_resumptions: non_neg_integer(),
          verification_retries: non_neg_integer()
        }

  @type intent :: %{
          id: String.t(),
          slug: String.t(),
          title: String.t(),
          may_change_guarded_paths: [String.t()],
          raw: map()
        }

  @doc """
  Reads the tracked Kogen configuration and resolves one named route.

  `route` names the route to select; `nil` selects the configured
  `default_route`, the only default. Every route is checked for structure and
  no key has a default. Harness support and Claude Code proven models are
  checked only for the selected route. The old flat shape is refused.

  On success returns `{:ok, config}`: the selected route's `harness`, role and
  helper profiles, the global retry policy, and `route` (the selected name),
  with atom keys regardless of whether the YAML parser produced string or
  atom keys.
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
         :ok <- supported_harness(selected.harness),
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
         {:ok, harness} <- require_string(route, "harness", "harness"),
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
         helpers: helpers
       }}
    else
      {:error, "config.yaml " <> _reason} = error -> error
      {:error, key} -> {:error, "config.yaml missing required key: routes.#{name}.#{key}"}
    end
  end

  defp normalize_route(name, _route) when is_binary(name),
    do: {:error, "config.yaml missing required key: routes.#{name}"}

  defp normalize_route(name, _route),
    do: {:error, "config.yaml route names must be nonblank strings: #{inspect(name)}"}

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
  # model without blocking sessions on other routes.
  defp proven_models(%{harness: "claude"} = config) do
    with {:ok, models} <- claude_models() do
      proven = Map.new(models, &{&1["id"], &1["efforts"]})

      Enum.find_value(@claude_roles, :ok, fn {label, keys} ->
        proven_profile(label, get_in(config, keys), proven, models)
      end)
    end
  end

  defp proven_models(_config), do: :ok

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

  defp supported_harness(name) when name in @harnesses, do: :ok

  defp supported_harness(name),
    do: {:error, "unsupported harness: #{name}; expected #{Enum.join(@harnesses, " or ")}"}

  defp normalize_intent(data, slug) do
    with {:ok, id} <- require_string(data, "id", "id"),
         {:ok, title} <- require_string(data, "title", "title"),
         {:ok, guarded} <- require_nonempty_list(data, "may_change_guarded_paths"),
         {:ok, ^slug} <- require_string(data, "slug", "slug") do
      {:ok,
       %{
         id: id,
         slug: slug,
         title: title,
         may_change_guarded_paths: guarded,
         raw: data
       }}
    else
      {:error, missing_key} -> {:error, "intent.yaml missing required key: #{missing_key}"}
      {:ok, _other_slug} -> {:error, "intent.yaml slug does not match selected slug: #{slug}"}
    end
  end

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

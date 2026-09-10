defmodule Kogen.Intent do
  use Boundary, deps: []

  @moduledoc """
  Reads and validates the tracked `.kogen/config.yaml` and per-slug
  `intent.yaml` files, and mints RFC 9562 UUIDv7 identifiers.

  This is a leaf compartment: it reads YAML off disk (via `YamlElixir`)
  and depends on nothing else in the application.
  """

  @default_config_path ".kogen/config.yaml"

  @type role_config :: %{model: String.t(), effort: String.t()}

  @type config :: %{
          harness: String.t(),
          shaping: role_config(),
          developer: role_config(),
          reviewer: role_config(),
          helpers: %{
            scout: role_config(),
            worker: role_config(),
            expert: role_config()
          },
          outer_resumptions: integer()
        }

  @type intent :: %{
          id: String.t(),
          slug: String.t(),
          title: String.t(),
          may_change_guarded_paths: [String.t()],
          raw: map()
        }

  @doc """
  Reads and validates the tracked Kogen configuration file.

  Refuses to start (returns `{:error, reason}`) when the file is missing
  or a required key is absent; no defaults are invented. On success
  returns `{:ok, config}` with atom keys regardless of whether the
  underlying YAML parser produced string or atom keys.
  """
  @spec read_config(Path.t()) :: {:ok, config()} | {:error, String.t()}
  def read_config(path \\ @default_config_path) do
    with {:ok, data} <- load_yaml(path, "missing #{path}"),
         {:ok, config} <- normalize_config(data),
         :ok <- supported_harness(config.harness) do
      {:ok, config}
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

  defp supported_harness("codex"), do: :ok
  defp supported_harness(name), do: {:error, "unsupported harness: #{name}; expected codex"}

  defp normalize_config(data) do
    with {:ok, harness} <- require_string(data, "harness", "harness"),
         {:ok, shaping} <- require_role(data, "shaping"),
         {:ok, developer} <- require_role(data, "developer"),
         {:ok, reviewer} <- require_role(data, "reviewer"),
         {:ok, helpers} <- require_helpers(data),
         {:ok, outer_resumptions} <- require_integer(data, "outer_resumptions") do
      {:ok,
       %{
         harness: harness,
         shaping: shaping,
         developer: developer,
         reviewer: reviewer,
         helpers: helpers,
         outer_resumptions: outer_resumptions
       }}
    else
      {:error, missing_key} -> {:error, "config.yaml missing required key: #{missing_key}"}
    end
  end

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

defmodule Kogen.RouteConfig do
  @moduledoc false
  # Shared routes-shaped `.kogen/config.yaml` builders for offline fixtures, and
  # the Codex-route resolver used by Codex-only live owners. Every rendered key
  # is explicit: the routes parser has no defaults, so neither do these routes.

  @codex %{
    "harness" => "codex",
    "shaping" => %{"model" => "gpt-6-sol", "effort" => "medium"},
    "developer" => %{"model" => "gpt-6-sol", "effort" => "medium"},
    "reviewer" => %{"model" => "gpt-6-sol", "effort" => "high"},
    "helpers" => %{
      "scout" => %{"model" => "gpt-6-luna", "effort" => "low"},
      "worker" => %{"model" => "gpt-6-luna", "effort" => "high"},
      "expert" => %{"model" => "gpt-6-sol", "effort" => "high"}
    }
  }

  @claude %{
    "harness" => "claude",
    "shaping" => %{"model" => "claude-opus-5-5", "effort" => "medium"},
    "developer" => %{"model" => "claude-opus-5-5", "effort" => "medium"},
    "reviewer" => %{"model" => "claude-opus-5-5", "effort" => "medium"},
    "helpers" => %{
      "scout" => %{"model" => "claude-sonnet-5", "effort" => "low"},
      "worker" => %{"model" => "claude-sonnet-5", "effort" => "medium"},
      "expert" => %{"model" => "claude-opus-5-5", "effort" => "high"}
    }
  }

  @key_order ~w(default_route routes harness shaping developer reviewer helpers scout worker expert model effort outer_resumptions verification_retries)

  @doc "The Codex route profiles restored from before the Claude Code switch."
  def codex_route(overrides \\ %{}), do: deep_merge(@codex, overrides)

  @doc "This repository's Claude Code route profiles."
  def claude_route(overrides \\ %{}), do: deep_merge(@claude, overrides)

  @doc """
  Renders a routes config. `routes` is an ordered list of `{name, route}`;
  `:default_route` defaults to the first route's name only in this builder so
  fixtures stay short. Pass `default_route: nil` to omit the key.
  """
  def yaml(routes \\ [{"codex", codex_route()}], opts \\ []) do
    [{first, _route} | _rest] = routes

    %{
      "default_route" => Keyword.get(opts, :default_route, first),
      "routes" => Map.new(routes),
      "outer_resumptions" => Keyword.get(opts, :outer_resumptions, 2),
      "verification_retries" => Keyword.get(opts, :verification_retries, 2)
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> render(0)
  end

  @doc "Writes a routes config (see `yaml/2`) to `path`, creating its directory."
  def write!(path, routes \\ [{"codex", codex_route()}], opts \\ []) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, yaml(routes, opts))
    path
  end

  @doc """
  Resolves the one route whose harness is `codex`, for Codex-only live owners.
  Never uses `default_route`; zero or several Codex routes fail loudly, listing
  the candidates.
  """
  def codex_route!(path \\ ".kogen/config.yaml") do
    {:ok, data} = YamlElixir.read_from_file(path)
    routes = Map.get(data, "routes")

    unless is_map(routes) do
      raise "#{path} has no routes; Codex-only live owners need exactly one codex route"
    end

    candidates =
      routes
      |> Enum.filter(fn {_name, route} -> is_map(route) and route["harness"] == "codex" end)
      |> Enum.map(fn {name, _route} -> to_string(name) end)
      |> Enum.sort()

    case candidates do
      [name] ->
        case Kogen.Intent.read_config(path, name) do
          {:ok, config} -> config
          {:error, reason} -> raise "codex route #{name} in #{path} is invalid: #{reason}"
        end

      _ ->
        raise "#{path} must define exactly one route with harness codex for Codex-only live owners; codex candidates: #{inspect(candidates)}"
    end
  end

  defp deep_merge(left, right) do
    Map.merge(left, right, fn
      _key, %{} = l, %{} = r -> deep_merge(l, r)
      _key, _l, r -> r
    end)
  end

  defp render(map, indent) do
    map
    |> Enum.sort_by(fn {key, _value} -> {order(key), key} end)
    |> Enum.map_join(fn
      {key, %{} = value} ->
        "#{pad(indent)}#{key}:\n" <> render(value, indent + 2)

      {key, value} ->
        "#{pad(indent)}#{key}: #{scalar(value)}\n"
    end)
  end

  defp order(key), do: Enum.find_index(@key_order, &(&1 == key)) || length(@key_order)
  defp pad(indent), do: String.duplicate(" ", indent)
  defp scalar(value) when is_binary(value), do: Jason.encode!(value)
  defp scalar(value), do: to_string(value)
end

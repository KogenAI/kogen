defmodule Kogen.EngineResources do
  @moduledoc """
  Resolves engine-owned source and prompt resources from the loaded Kogen
  application, independent of the target project or process working directory.
  """
  use Boundary, deps: [Kogen.ProjectScope]

  @doc "The source checkout from which the Kogen application was loaded."
  @spec root() :: Path.t()
  def root do
    Path.expand("../..", __DIR__) |> Kogen.ProjectScope.canonical()
  end

  @doc "Resolves an existing relative resource path under an engine checkout."
  @spec path(Path.t(), Path.t()) :: {:ok, Path.t()} | {:error, String.t()}
  def path(relative, engine_root \\ root()) do
    root = Kogen.ProjectScope.canonical(engine_root)

    cond do
      Path.type(relative) == :absolute ->
        {:error, "engine resource path must be relative: #{relative}"}

      not File.dir?(root) ->
        {:error, "engine resource root is unavailable: #{root}"}

      true ->
        resolved = relative |> Path.expand(root) |> Kogen.ProjectScope.canonical()

        cond do
          not within?(resolved, root) ->
            {:error, "engine resource path escapes its checkout: #{relative}"}

          not File.exists?(resolved) ->
            {:error, "engine resource is missing: #{relative}"}

          true ->
            {:ok, resolved}
        end
    end
  end

  defp within?(path, root) do
    path_parts = Path.split(Path.expand(path))
    root_parts = Path.split(Path.expand(root))
    Enum.take(path_parts, length(root_parts)) == root_parts
  end
end

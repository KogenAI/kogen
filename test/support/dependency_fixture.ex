defmodule Kogen.DependencyFixture do
  @moduledoc false

  @excluded_paths ["_build", "ebin", ".git"]

  @doc """
  Copies installed dependency sources into a fixture-owned directory.

  Build products are deliberately omitted: Rebar may keep its own `_build`
  state inside a dependency source tree, and a fixture must never share it.
  """
  @spec copy!(Path.t(), Path.t()) :: Path.t()
  def copy!(source_deps, destination_deps) do
    source_deps = Path.expand(source_deps)
    destination_deps = Path.expand(destination_deps)

    unless File.dir?(source_deps) do
      raise ArgumentError, "dependency source directory does not exist: #{source_deps}"
    end

    File.mkdir_p!(destination_deps)

    args =
      ["-a"] ++
        Enum.flat_map(@excluded_paths, &["--exclude", &1]) ++
        [source_deps <> "/", destination_deps <> "/"]

    case System.cmd("rsync", args, stderr_to_stdout: true) do
      {_output, 0} -> destination_deps
      {output, status} -> raise "dependency source copy failed (exit #{status}): #{output}"
    end
  end
end

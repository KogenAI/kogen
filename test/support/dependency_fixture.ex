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

    case File.lstat(destination_deps) do
      {:error, :enoent} ->
        :ok

      {:ok, _stat} ->
        raise ArgumentError, "dependency destination already exists: #{destination_deps}"

      {:error, reason} ->
        raise File.Error, reason: reason, action: "inspect", path: destination_deps
    end

    File.mkdir_p!(Path.dirname(destination_deps))
    File.mkdir!(destination_deps)

    # Materialize linked source data. Dependency tools write into their source
    # trees, so preserving a symlink would alias fixture writes back into the
    # installed dependency or another fixture.
    args =
      ["-a", "--copy-links"] ++
        Enum.flat_map(@excluded_paths, &["--exclude", &1]) ++
        [source_deps <> "/", destination_deps <> "/"]

    try do
      case System.cmd("rsync", args, stderr_to_stdout: true) do
        {_output, 0} ->
          destination_deps

        {output, status} ->
          raise "dependency source copy failed (exit #{status}): #{output}"
      end
    rescue
      exception ->
        File.rm_rf(destination_deps)
        reraise exception, __STACKTRACE__
    end
  end
end

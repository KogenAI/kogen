defmodule Kogen.SharedOutcome do
  @moduledoc false
  # A module parameterized for one test reruns every other test once per
  # parameter set, each in its own isolated child VM. For a test whose body
  # ignores the parameters, every rerun produces the same outcome from the
  # same Candidate sources. `fetch!/2` produces that outcome once per suite run
  # and hands the same plain-data result to every rerun, which then makes all
  # of its own assertions against it: no test ID is skipped and no assertion
  # is removed; only the identical fixture work is not repeated.
  #
  # The suite's parent creates a fresh directory and names it in
  # `KOGEN_SHARED_OUTCOME_DIR`; without it (a single focused child, or a
  # nested suite that did not create one) the outcome is produced locally.
  # A failed or abandoned producer never blocks a rerun: it produces locally.

  @variable "KOGEN_SHARED_OUTCOME_DIR"
  @wait_ms 240_000
  @poll_ms 100

  def variable, do: @variable

  @doc "Produces or reuses the outcome of `fun` (plain data only) for `key`."
  def fetch!(key, fun) when is_binary(key) and is_function(fun, 0),
    do: fetch!(key, fun, System.get_env(@variable))

  @doc "As `fetch!/2`, sharing through `dir` instead of the suite variable."
  def fetch!(key, fun, dir) when is_binary(key) and is_function(fun, 0) do
    case dir do
      dir when is_binary(dir) and dir != "" ->
        if File.dir?(dir), do: shared(dir, key, fun), else: fun.()

      _unset ->
        fun.()
    end
  end

  defp shared(dir, key, fun) do
    name = :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)

    paths = %{
      result: Path.join(dir, name <> ".term"),
      failed: Path.join(dir, name <> ".failed"),
      lock: Path.join(dir, name <> ".lock")
    }

    case File.mkdir(paths.lock) do
      :ok -> produce(paths, fun)
      {:error, :eexist} -> await(paths, fun, System.monotonic_time(:millisecond) + @wait_ms)
      {:error, _reason} -> fun.()
    end
  end

  defp produce(paths, fun) do
    value = fun.()
    temporary = paths.result <> ".#{System.unique_integer([:positive])}"
    File.write!(temporary, :erlang.term_to_binary(value))
    File.rename!(temporary, paths.result)
    value
  rescue
    error ->
      File.write(paths.failed, "")
      reraise error, __STACKTRACE__
  end

  defp await(paths, fun, deadline) do
    cond do
      File.regular?(paths.result) ->
        paths.result |> File.read!() |> :erlang.binary_to_term()

      File.regular?(paths.failed) or System.monotonic_time(:millisecond) > deadline ->
        fun.()

      true ->
        Process.sleep(@poll_ms)
        await(paths, fun, deadline)
    end
  end
end

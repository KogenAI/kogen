defmodule Kogen.Check do
  @moduledoc """
  The Verification Record (written by the tracked Stop hook,
  `.codex/hooks/check.sh`) and declared-target verification. Never depends
  on `Kogen.Harness`: whether a Verification Record is trustworthy must be
  decidable without knowing anything about how the Developer was launched.
  """
  use Boundary, deps: []

  @record_path ".kogen/runtime/verification.json"
  @history_path ".kogen/runtime/verification-history.jsonl"
  @target_name_re ~r/^[a-z][a-z0-9_-]*$/

  @doc "Path to the ignored Verification Record the Stop hook writes."
  def record_path, do: @record_path

  @doc """
  Path to the ignored, append-only history of every hook invocation (one
  JSON line each) for the current attempt. A later passing
  `verification.json` overwrites the evidence that an earlier attempt
  within the same turn failed; this file is what still has it, so a real
  failed-Check -> in-turn-continuation -> pass arc can be proven after the
  fact instead of merely inferred from a higher turn count.
  """
  def history_path, do: @history_path

  @doc """
  Deletes any prior local Verification Record and history. When private raw
  logging is enabled, preserves the prior history in the requested private
  log directory first.
  This keeps each outer attempt's active history fresh without discarding
  evidence needed to audit a later resume.
  """
  @spec invalidate!() :: :ok | {:error, String.t()}
  def invalidate! do
    with :ok <- archive_history_if_requested(),
         :ok <- remove_stale_file(@record_path, "Verification Record") do
      remove_stale_file(@history_path, "Verification Record history")
    end
  end

  @doc "Reads and parses the Verification Record, or `:error` if absent/invalid JSON."
  @spec read_record(Path.t()) :: {:ok, map()} | :error
  def read_record(root \\ ".") do
    with {:ok, content} <- File.read(Path.join(root, @record_path)),
         {:ok, json} when is_map(json) <- Jason.decode(content) do
      {:ok, json}
    else
      _ -> :error
    end
  end

  @doc """
  Whether the current Verification Record proves a settled Check pass for
  exactly `candidate_id` and `session_id`. A missing, stale (different
  candidate or session), wrong target, nonzero Check exit, or failed record
  is not a pass.
  """
  @spec settled_pass?(String.t(), String.t(), Path.t()) :: boolean()
  def settled_pass?(candidate_id, session_id, root \\ ".") do
    case read_record(root) do
      {:ok,
       %{
         "candidate" => ^candidate_id,
         "status" => "passed",
         "target" => "check",
         "session_id" => ^session_id,
         "exit_code" => 0
       }} ->
        true

      _ ->
        false
    end
  end

  @doc "A short, human reason describing why the current record does not settle a pass."
  @spec settlement_failure_reason(String.t(), String.t(), Path.t()) :: String.t()
  def settlement_failure_reason(candidate_id, session_id, root \\ ".") do
    case read_record(root) do
      :error ->
        "no Verification Record was written"

      {:ok, record} ->
        record_failure_reason(record, candidate_id, session_id)
    end
  end

  @doc "Whether `name` is safe to interpolate into a shell `make` invocation."
  @spec valid_target_name?(String.t()) :: boolean()
  def valid_target_name?(name), do: is_binary(name) and Regex.match?(@target_name_re, name)

  @doc "The set of target names declared in `makefile_path` (rule lines only, not recipes)."
  @spec declared_targets(Path.t()) :: MapSet.t(String.t())
  def declared_targets(makefile_path \\ "Makefile") do
    case File.read(makefile_path) do
      {:ok, content} ->
        ~r/^([A-Za-z0-9_.-]+)\s*:(?!=)/m
        |> Regex.scan(content)
        |> Enum.map(fn [_, name] -> name end)
        |> MapSet.new()

      {:error, _} ->
        MapSet.new()
    end
  end

  @doc """
  Validates every name in `names` (excluding `"check"`, which already ran)
  is both a safe shell token and a target actually declared in the
  Makefile. Must be called, and must succeed, before the Developer is
  launched.
  """
  @spec validate_targets([String.t()], Path.t()) :: :ok | {:error, String.t()}
  def validate_targets(names, makefile_path \\ "Makefile") do
    declared = declared_targets(makefile_path)

    names
    |> Enum.reject(&(&1 == "check"))
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn name, :ok ->
      cond do
        not valid_target_name?(name) ->
          {:halt, {:error, "refused unsafe target name: #{inspect(name)}"}}

        not MapSet.member?(declared, name) ->
          {:halt, {:error, "undeclared make target: #{name}"}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  @doc "Runs `make <name>`, returning captured combined output either way."
  @spec run_target(String.t(), Path.t()) ::
          {:ok, String.t()} | {:error, {non_neg_integer(), String.t()}}
  def run_target(name, root \\ ".") do
    case System.cmd("make", [name], cd: root, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, {code, out}}
    end
  end

  defp archive_history_if_requested do
    case {System.get_env("KOGEN_RAW_LOG_DIR"), File.read(@history_path)} do
      {dir, {:ok, history}} when is_binary(dir) and byte_size(history) > 0 ->
        name =
          "verification-history-#{System.pid()}-#{:erlang.unique_integer([:positive, :monotonic])}.jsonl"

        with :ok <- File.mkdir_p(dir),
             :ok <- File.write(Path.join(dir, name), history) do
          :ok
        else
          {:error, reason} ->
            {:error,
             "could not archive Verification Record history: #{:file.format_error(reason)}"}
        end

      {_dir, {:error, :enoent}} ->
        :ok

      {_dir, {:error, reason}} ->
        {:error, "could not read Verification Record history: #{:file.format_error(reason)}"}

      _ ->
        :ok
    end
  end

  defp remove_stale_file(path, label) do
    case File.rm(path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, "could not clear stale #{label}: #{:file.format_error(reason)}"}
    end
  end

  defp record_failure_reason(record, candidate_id, session_id) do
    [
      {"session_id", session_id,
       fn -> "Verification Record session_id does not match the Developer session" end},
      {"candidate", candidate_id,
       fn -> "Verification Record candidate does not match the current tree" end},
      {"status", "passed",
       fn ->
         tail = Map.get(record, "reason") || Map.get(record, "status")
         "make check failed: #{tail}"
       end},
      {"target", "check", fn -> "Verification Record target is not check" end},
      {"exit_code", 0, fn -> "Verification Record check exit_code is not 0" end}
    ]
    |> Enum.find_value("Verification Record does not settle a pass", fn {field, expected, message} ->
      if Map.get(record, field) == expected, do: nil, else: message.()
    end)
  end
end

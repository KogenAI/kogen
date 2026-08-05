defmodule CodegenTestHarness.BenchManifest do
  @moduledoc """
  Reads and writes the `manifest.json` file inside a benchmark run directory.

  Writes are atomic: content is written to `manifest.json.<unique_integer>` via
  `File.write!/2` then renamed to `manifest.json` via `File.rename!/2` (POSIX
  atomic on same filesystem). On rename collision the manifest is re-read and
  retried up to 3 times. Raises if the stored `model_resolution` value for a
  (harness, role) pair differs from the new value — this signals a mid-sweep
  CLI swap.

  No GenServer or supervision tree required: the `test_harness/` application
  has no supervision tree, so atomic file rename is the correct primitive.
  """

  @max_rename_retries 3

  @doc """
  Writes `reason.txt` and a skeleton `manifest.json` to `run_dir`.

  The skeleton contains:
  - `codegen_sha` — current git HEAD
  - `harness_versions` — `%{"claude" => version}`
  - `started_at` — ISO-8601 UTC timestamp
  - `model_resolution` — empty map (populated lazily by `record_resolution/4`)

  Raises on filesystem errors.
  """
  @spec start_run(String.t(), String.t()) :: :ok
  def start_run(run_dir, reason) do
    File.mkdir_p!(run_dir)
    File.write!(Path.join(run_dir, "reason.txt"), reason)

    {claude_version, _} = System.cmd("claude", ["--version"], stderr_to_stdout: true)

    {sha, _} =
      System.cmd("git", ["rev-parse", "HEAD"],
        stderr_to_stdout: true,
        cd: Path.expand("../../..", __DIR__)
      )

    skeleton = %{
      "codegen_sha" => String.trim(sha),
      "harness_versions" => %{
        "claude" => String.trim(claude_version)
      },
      "started_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "model_resolution" => %{}
    }

    manifest_path = Path.join(run_dir, "manifest.json")
    File.write!(manifest_path, Jason.encode!(skeleton, pretty: true))
    :ok
  end

  @doc """
  Merges `resolved_id` into the manifest's `model_resolution` for the given
  `harness` + `role` key (written as `"<harness>/<role>"`).

  Idempotent: if the existing value equals `resolved_id`, does nothing.
  Raises if the existing value differs (mid-sweep CLI swap detected).

  Uses atomic write-to-tmp + rename with up to #{@max_rename_retries} retries
  on collision.
  """
  @spec record_resolution(String.t(), String.t(), String.t(), String.t()) :: :ok
  def record_resolution(run_dir, harness, role, resolved_id) do
    key = "#{harness}/#{role}"
    do_record_resolution(run_dir, key, resolved_id, 0)
  end

  @doc """
  Reads and decodes `manifest.json` from `run_dir`. Returns the decoded map.
  """
  @spec load(String.t()) :: map()
  def load(run_dir) do
    run_dir
    |> Path.join("manifest.json")
    |> File.read!()
    |> Jason.decode!()
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp do_record_resolution(run_dir, key, resolved_id, attempt)
       when attempt <= @max_rename_retries do
    manifest = load(run_dir)
    resolution = Map.get(manifest, "model_resolution", %{})

    case Map.get(resolution, key) do
      nil ->
        updated = Map.put(resolution, key, resolved_id)
        updated_manifest = Map.put(manifest, "model_resolution", updated)

        try do
          write_manifest_atomic(run_dir, updated_manifest)
        rescue
          File.Error ->
            if attempt < @max_rename_retries do
              do_record_resolution(run_dir, key, resolved_id, attempt + 1)
            else
              reraise "BenchManifest: could not write manifest after #{@max_rename_retries} retries",
                      __STACKTRACE__
            end
        end

      ^resolved_id ->
        :ok

      existing ->
        raise "BenchManifest: resolution conflict for #{key}: " <>
                "existing=#{inspect(existing)} new=#{inspect(resolved_id)}"
    end
  end

  defp write_manifest_atomic(run_dir, manifest) do
    manifest_path = Path.join(run_dir, "manifest.json")
    tmp_path = "#{manifest_path}.#{:erlang.unique_integer([:positive])}"
    File.write!(tmp_path, Jason.encode!(manifest, pretty: true))
    File.rename!(tmp_path, manifest_path)
    :ok
  end
end

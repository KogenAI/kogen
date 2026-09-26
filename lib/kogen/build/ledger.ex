defmodule Kogen.Build.Ledger do
  @moduledoc """
  The verification-surface ledger and the base-suite report.

  When the admission catalog declares `verification_surface`, the controller
  computes the ledger from Git (Candidate tree against the admission commit)
  before Review. Every changed, deleted or renamed path matching the test or
  runner globs is an item, including paths outside every scenario's
  `affected_paths`; an added test-class file is left out and an added
  runner-class file is included. An edited `proof.base: pass` selector is an
  item too. Each item's full diff is a controller-retained file under the
  attempt's verification directory, bound by sha256; only its index entry
  travels in the handoff report and the review packet, never to Jev. The
  ledger also names the receipts that ran with changed runner-class files and
  the catalog digest change.

  The base-suite report runs base's test files and runner in a scratch copy
  of the base workspace with only the Candidate's implementation files
  overlaid. It is a report for Review, not a gate.
  """

  alias Kogen.Build.{BaseWorkspace, ProofSelectors, VerificationPlan, VerificationRunner}

  @doc """
  Computes the ledger, or `{:ok, nil}` without integrity fields. `input`
  holds `:root`, `:base_commit`, `:candidate_id`, `:integrity`,
  `:admission_sha256`, `:candidate_sha256`, `:receipts`, `:directory` and
  `:preservation` (edited preservation selector paths).
  """
  def compute(%{integrity: nil}), do: {:ok, nil}

  def compute(input) do
    surface = input.integrity["verification_surface"]

    with {:ok, changes} <-
           Kogen.Git.tree_changes(input.base_commit, input.candidate_id, input.root),
         :ok <- File.mkdir_p(Path.join(input.directory, "ledger")) do
      surface_changes =
        Enum.filter(changes, fn change ->
          paths = Enum.reject([change["path"], change["old_path"]], &is_nil/1)
          runner? = Enum.any?(paths, &ProofSelectors.runner_class?(&1, surface))
          test? = Enum.any?(paths, &ProofSelectors.test_class?(&1, surface))

          runner? or (test? and change["status"] != "added") or
            change["path"] in input.preservation
        end)

      items =
        surface_changes
        |> Enum.with_index(1)
        |> Enum.map(fn {change, index} -> item(input, surface, change, index) end)

      case Enum.find(items, &match?({:error, _}, &1)) do
        nil -> {:ok, ledger(input, Enum.map(items, &elem(&1, 1)))}
        error -> error
      end
    end
  end

  defp item(input, surface, change, index) do
    paths = Enum.reject([change["old_path"], change["path"]], &is_nil/1)
    name = "#{String.pad_leading(Integer.to_string(index), 4, "0")}.diff"
    diff_path = Path.join([input.directory, "ledger", name])

    with {:ok, diff} <-
           Kogen.Git.path_diff(input.base_commit, input.candidate_id, paths, input.root),
         :ok <- exclusive_write(diff_path, diff) do
      {:ok,
       %{
         "path" => change["path"],
         "status" => change["status"],
         "old_path" => change["old_path"],
         "runner_class" => Enum.any?(paths, &ProofSelectors.runner_class?(&1, surface)),
         "preservation_selector" => change["path"] in input.preservation,
         "base_blob" => change["base_blob"],
         "candidate_blob" => change["candidate_blob"],
         "diff_stat" => %{"added" => change["added"], "deleted" => change["deleted"]},
         "diff" => %{
           "path" => Path.relative_to(Path.expand(diff_path), Path.expand(input.root)),
           "sha256" => sha256(diff),
           "byte_count" => byte_size(diff)
         }
       }}
    end
  end

  defp ledger(input, items) do
    runner_changed? = Enum.any?(items, & &1["runner_class"])

    %{
      "schema_version" => 1,
      "base_commit" => input.base_commit,
      "candidate_id" => input.candidate_id,
      "items" => items,
      "receipts_with_changed_runner" =>
        if(runner_changed?,
          do:
            Enum.map(
              input.receipts,
              &%{"target" => &1["target"], "cycle_sequence" => &1["cycle_sequence"]}
            ),
          else: []
        ),
      "catalog" => %{
        "admission_sha256" => input.admission_sha256,
        "candidate_sha256" => input.candidate_sha256,
        "changed" => input.admission_sha256 != input.candidate_sha256
      }
    }
  end

  @doc "Confirms every retained ledger diff still has its bound bytes."
  def verify(nil, _root), do: :ok

  def verify(ledger, root) do
    Enum.reduce_while(ledger["items"], :ok, fn item, :ok ->
      case diff_unchanged(item["diff"], root) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp diff_unchanged(diff, root) do
    case File.read(Path.expand(diff["path"], root)) do
      {:ok, bytes} ->
        if sha256(bytes) == diff["sha256"],
          do: :ok,
          else: {:error, "ledger diff mutated: #{diff["path"]}"}

      _ ->
        {:error, "ledger diff missing: #{diff["path"]}"}
    end
  end

  @doc "The ledger paths the Reviewer must disposition."
  def paths(nil), do: []
  def paths(ledger), do: Enum.map(ledger["items"], & &1["path"])

  @doc """
  Runs base's test suite (the base files matching the test globs, with base's
  runner) against the Candidate's implementation files in a scratch copy of
  the base workspace. Returns `{report, workspace}`; the report is never a
  gate.
  """
  def base_suite(%{integrity: nil}), do: {nil, nil}

  def base_suite(input) do
    integrity = input.integrity
    surface = integrity["verification_surface"]

    with {:ok, changes} <-
           Kogen.Git.tree_changes(input.base_commit, input.candidate_id, input.root),
         {:ok, files} <- Kogen.Git.tree_files(input.base_commit, input.root),
         {:ok, workspace, _rebuilt?} <- BaseWorkspace.ensure(input.workspace) do
      tests = Enum.filter(files, &ProofSelectors.test_class?(&1, surface))
      overlays = implementation_overlays(changes, surface, input)
      {run_suite(input, workspace, tests, overlays), workspace}
    else
      {:error, reason} -> {error_report(input, reason), input.workspace}
    end
  end

  # Only the Candidate's implementation (non-surface) files are overlaid.
  defp implementation_overlays(changes, surface, input) do
    changes
    |> Enum.reject(fn change ->
      [change["path"], change["old_path"]]
      |> Enum.reject(&is_nil/1)
      |> Enum.any?(
        &(ProofSelectors.test_class?(&1, surface) or ProofSelectors.runner_class?(&1, surface))
      )
    end)
    |> Enum.flat_map(fn change ->
      removed = if change["old_path"], do: [{change["old_path"], :delete}], else: []
      removed ++ [implementation_overlay(change["path"], input)]
    end)
  end

  defp implementation_overlay(path, input) do
    case Kogen.Git.blob(input.candidate_id, path, input.root) do
      {:ok, bytes} -> {path, bytes}
      :absent -> {path, :delete}
    end
  end

  defp run_suite(input, _workspace, [], _overlays),
    do: %{
      "status" => "skipped",
      "reason" => "base has no test-class files",
      "base_commit" => input.base_commit,
      "use" => "report for Review, not a gate"
    }

  defp run_suite(input, workspace, tests, overlays) do
    argv =
      Enum.flat_map(
        input.integrity["focused_runner"],
        &if(&1 == "{paths}", do: tests, else: [&1])
      )

    log = Path.join(input.directory, "base-suite.log")
    timeout = Application.get_env(:kogen, :focused_runner_timeout_ms, 1_800_000)

    case BaseWorkspace.scratch(workspace, overlays) do
      {:ok, dir} ->
        try do
          case VerificationRunner.run(argv, dir, log,
                 timeout_ms: timeout,
                 env: BaseWorkspace.run_environment(dir)
               ) do
            {:ok, facts} ->
              %{
                "status" => VerificationRunner.status(facts),
                "exit_code" => facts["exit_code"],
                "timed_out" => facts["timed_out"],
                "base_commit" => input.base_commit,
                "candidate_id" => input.candidate_id,
                "overlay_sha256" => BaseWorkspace.overlay_digest(overlays),
                "log_path" => Path.relative_to(facts["log_path"], Path.expand(input.root)),
                "log_sha256" => facts["log_sha256"],
                "use" => "report for Review, not a gate"
              }

            {:error, reason} ->
              error_report(input, reason)
          end
        after
          File.rm_rf(dir)
        end

      {:error, reason} ->
        error_report(input, reason)
    end
  end

  defp error_report(input, reason),
    do: %{
      "status" => "error",
      "reason" => reason,
      "base_commit" => input.base_commit,
      "use" => "report for Review, not a gate"
    }

  @doc "Whether `path` lies in the admission verification surface."
  def surface?(path, integrity) do
    surface = integrity["verification_surface"]

    Enum.any?(surface["tests"] ++ surface["runner"], &VerificationPlan.path_matches?(path, &1))
  end

  defp exclusive_write(path, bytes) do
    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, io} ->
        result = IO.binwrite(io, bytes)
        File.close(io)
        result

      {:error, reason} ->
        {:error, "could not retain ledger diff #{path}: #{inspect(reason)}"}
    end
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end

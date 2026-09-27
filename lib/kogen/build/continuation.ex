# credo:disable-for-this-file Credo.Check.Refactor.CyclomaticComplexity
defmodule Kogen.Build.Continuation do
  @moduledoc """
  Admission checks and state needed to continue a kept Candidate.
  """

  alias Kogen.Build.{FailureReport, Tracking, Workspace}

  @runtime ".kogen/runtime/scenario-tracking"

  @doc "Finds the one eligible kept Candidate, or returns a refusal."
  def decide(control, slug, intent, config, approved_entries) do
    owners =
      Workspace.list(control)
      |> Enum.flat_map(fn
        {:ok, owner} -> if(owner["slug"] == slug, do: [owner], else: [])
        _ -> []
      end)

    entries = Enum.flat_map(owners, &current_entry(control, &1))
    candidates = Enum.filter(entries, &continuation_category?/1)

    cond do
      candidates == [] ->
        :none

      length(candidates) > 1 ->
        refuse("ambiguous", ambiguous_detail(candidates), hd(candidates), false)

      true ->
        validate(hd(candidates), control, intent, config, approved_entries)
    end
  end

  defp current_entry(control, owner) do
    id = Map.get(owner, "tracking_build_id") || owner["build_id"]
    record_path = Path.join([control, @runtime, id, "record.json"])
    report_path = FailureReport.report_path(control, id)

    with {:ok, record_bytes} <- File.read(record_path),
         {:ok, record} <- Jason.decode(record_bytes),
         {:ok, report_bytes} <- File.read(report_path),
         {:ok, report} <- Jason.decode(report_bytes) do
      [
        %{
          owner: owner,
          id: id,
          record_path: record_path,
          record_bytes: record_bytes,
          record: record,
          report_path: report_path,
          report_bytes: report_bytes,
          report: report
        }
      ]
    else
      _ -> []
    end
  end

  defp continuation_category?(%{report: %{"category" => category}}),
    do: category in ["provider", "interrupted", "publication-interrupted"]

  defp continuation_category?(_), do: false

  defp validate(entry, control, _intent, config, approved_entries) do
    owner = entry.owner
    report = entry.report

    checks = [
      {:record_changed, fn -> record_changed(entry, control) end},
      {:publication_started, fn -> report["category"] == "publication-interrupted" end},
      {:no_session, fn -> is_nil(report["developer_session_id"]) end},
      {:package_changed,
       fn -> report["approved_package_digest"] != Tracking.approved_digest(approved_entries) end},
      {:control_moved, fn -> control_moved?(control, owner) end},
      {:route_changed, fn -> route_changed?(entry, config, control) end},
      {:candidate_missing, fn -> candidate_missing?(control, owner, approved_entries) end},
      {:budgets_exhausted, fn -> budgets_exhausted?(report) end}
    ]

    case Enum.find(checks, fn {_name, fun} -> fun.() end) do
      nil ->
        {:ok, entry}

      {:record_changed, _} ->
        refuse("record-changed", "the current record bytes differ from the report", entry, false)

      {:publication_started, _} ->
        refuse("publication-started", "publication had already started", entry, true)

      {:no_session, _} ->
        refuse("no-session", "the stopped Build has no Developer session", entry, false)

      {:package_changed, _} ->
        refuse("package-changed", "the Approved package digest changed", entry, false)

      {:control_moved, _} ->
        refuse("control-moved", "the admitted branch or commit moved", entry, false)

      {:route_changed, _} ->
        refuse("route-changed", "resolved route differs from the admitted route", entry, false)

      {:candidate_missing, _} ->
        refuse(
          "candidate-missing",
          "the kept Candidate or its Approved copy is missing",
          entry,
          false
        )

      {:budgets_exhausted, _} ->
        refuse("budgets-exhausted", "the persisted retry budget is exhausted", entry, false)
    end
  end

  defp route_check(entry, config, control) do
    expected = get_in(entry.record, ["route", "name"])
    actual = config[:route] || config["route"]

    with true <- expected == actual,
         {:ok, bindings} <-
           Kogen.Harness.bindings(config, [:developer, :reviewer, :expert], control),
         resolved <- binding_records(bindings),
         true <- resolved == entry.owner["credential_bindings"] do
      :ok
    else
      _ ->
        {:error, "route-changed",
         "resolved route or credential bindings differ from the admitted route"}
    end
  end

  defp route_changed?(entry, config, control), do: route_check(entry, config, control) != :ok

  defp binding_records(bindings) do
    bindings
    |> Enum.sort()
    |> Enum.map(fn {_harness, binding} -> Kogen.Harness.binding_record(binding) end)
  end

  defp record_changed(entry, control) do
    hash = sha(entry.record_bytes)
    state = entry.report["budget_state"]

    state_changed? =
      is_map(state) and is_binary(state["state"]) and is_binary(state["state_sha256"]) and
        case File.read(Path.expand(state["state"], control)) do
          {:ok, bytes} -> sha(bytes) != state["state_sha256"]
          _ -> true
        end

    hash != entry.report["record_sha256"] or state_changed?
  end

  defp control_moved?(control, owner) do
    Workspace.branch_commit(control, owner["admitted_branch"]) != owner["admitted_commit"] or
      branch_name(control) != owner["admitted_branch"]
  end

  defp branch_name(control) do
    case System.cmd("git", ["symbolic-ref", "--short", "-q", "HEAD"],
           cd: control,
           stderr_to_stdout: true
         ) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  defp candidate_missing?(control, owner, approved_entries) do
    with true <- is_binary(owner["worktree_path"]) and File.dir?(owner["worktree_path"]),
         true <- is_binary(owner["harness_home"]) and File.dir?(owner["harness_home"]),
         ^owner <- owner,
         true <-
           Workspace.branch_commit(control, owner["branch"]) == owner["candidate_commit"] ||
             Workspace.branch_commit(control, owner["branch"]) == owner["admitted_commit"],
         true <- worktree_head(owner["worktree_path"]) == owner["admitted_commit"],
         true <- package_matches?(owner["worktree_path"], owner["slug"], approved_entries) do
      false
    else
      _ -> true
    end
  end

  defp worktree_head(path) do
    case System.cmd("git", ["rev-parse", "HEAD"], cd: path, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  defp package_matches?(root, slug, entries) do
    path = Path.join([root, ".kogen/intents/approved", slug])
    File.dir?(path) and package_entries(path, "") == entries
  rescue
    _ -> false
  end

  defp package_entries(root, relative) do
    path = Path.join(root, relative)
    stat = File.lstat!(path)

    case stat.type do
      :directory ->
        [
          {relative, :directory, stat.mode}
          | Enum.flat_map(
              Enum.sort(File.ls!(path)),
              &package_entries(root, Path.join(relative, &1))
            )
        ]

      :regular ->
        [{relative, :regular, stat.mode, File.read!(path)}]

      _ ->
        [{relative, stat.type}]
    end
  end

  defp budgets_exhausted?(%{"budget_state" => %{"terminal_state" => state}}),
    do: state in ["exhausted", "offline_exhausted", "environment"]

  defp budgets_exhausted?(_), do: false

  defp ambiguous_detail(entries),
    do:
      "multiple kept Candidates qualify (#{Enum.map_join(entries, ", ", & &1.owner["build_id"])})"

  defp refuse(name, detail, entry, publication?) do
    owner = entry.owner
    candidate = candidate_map(owner)

    action =
      cond do
        publication? ->
          "inspect: fast-forward #{owner["admitted_branch"]} to the Candidate commit yourself, or `mix kogen.candidates.remove #{owner["build_id"]} --discard-accepted`"

        name == "route-changed" ->
          "rerun with `--route #{get_in(entry.record, ["route", "name"]) || "codex"}`"

        true ->
          "remove the Candidate, then rebuild"
      end

    {:error,
     "Continuation refused (#{name}): #{detail}; #{Workspace.retained_description(candidate, discard_accepted: publication?)}; next action: #{action}"}
  end

  defp candidate_map(owner) do
    %{
      build_id: owner["build_id"],
      slug: owner["slug"],
      title: owner["title"],
      intent_id: owner["intent_id"],
      control: owner["control_root"],
      path: owner["worktree_path"],
      branch: owner["branch"],
      admitted_branch: owner["admitted_branch"],
      admitted_commit: owner["admitted_commit"],
      harness_home: owner["harness_home"],
      owner_path: Workspace.owner_path(owner["control_root"], owner["build_id"]),
      bindings: owner["credential_bindings"] || [],
      started_at: owner["started_at"],
      tracking_build_id: owner["tracking_build_id"]
    }
  end

  def sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end

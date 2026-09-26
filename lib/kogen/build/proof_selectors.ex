defmodule Kogen.Build.ProofSelectors do
  @moduledoc """
  Controller-run scenario proof selectors, used when the admission catalog
  declares the integrity fields.

  After a cycle's targets pass, the controller runs each scenario's file
  selectors on the Candidate with the admission `focused_runner`; they must
  pass. For `proof.base: fail` it also runs them in a scratch copy of the
  admission base workspace, overlaying only the Candidate's bytes of that
  scenario's selector files and of changed test-class files (never
  runner-class or implementation files). There the run must exit nonzero:
  exit zero means the proof cannot detect the change, and a timeout or
  infrastructure error is an error, never a red result. A red receipt is
  reused while the overlay and base workspace digests are unchanged. For
  `proof.base: pass`, a selector differing from base must still pass with
  base's bytes on the Candidate. Contracts without `proof.base` get only the
  Candidate run and the `unproven-on-base` label.
  """

  alias Kogen.Build.{BaseWorkspace, Verification, VerificationPlan, VerificationRunner}

  @load_error ~r/CompileError|SyntaxError|TokenMissingError|MismatchedDelimiterError|== Compilation error|could not compile|\(module [^)]+ is not available\)/

  @doc """
  Runs the proof selectors of every planned scenario. Returns
  `{proofs, failure_or_nil, execution}`; the execution carries the (possibly
  rebuilt) base workspace.
  """
  def run(execution, base, env) do
    integrity = env.catalog.integrity
    workspace = execution.workspace || Map.get(env, :workspace)
    state = %{execution: %{execution | workspace: workspace}, proofs: [], failure: nil}

    env.plan.scenarios
    |> Enum.reject(&(&1["file_selectors"] == []))
    |> Enum.reduce_while(state, fn scenario, acc ->
      acc = run_scenario(acc, scenario, base, env, integrity)
      if acc.failure, do: {:halt, acc}, else: {:cont, acc}
    end)
    |> then(&{&1.proofs, &1.failure, &1.execution})
  end

  defp run_scenario(acc, scenario, base, env, integrity) do
    selectors = scenario["file_selectors"]

    receipt =
      focused(acc.execution, base, env, integrity, env.root, selectors, [], %{
        "scenario" => scenario["id"],
        "kind" => "candidate",
        "label" => scenario["label"]
      })

    acc = add(acc, receipt)

    cond do
      receipt["status"] != "passed" ->
        fail(acc, receipt, "scenario #{scenario["id"]} proof selectors fail on the Candidate")

      scenario["base"] == "fail" ->
        red_on_base(acc, scenario, base, env, integrity)

      scenario["base"] == "pass" ->
        preservation(acc, scenario, base, env, integrity)

      true ->
        acc
    end
  end

  defp red_on_base(acc, scenario, base, env, integrity) do
    with {:ok, overlays} <- red_overlays(scenario, base, env, integrity),
         {:ok, workspace, rebuilt?} <- BaseWorkspace.ensure(acc.execution.workspace) do
      acc = %{acc | execution: %{acc.execution | workspace: workspace}}
      overlay_sha = BaseWorkspace.overlay_digest(overlays)

      case prior_red(acc.execution.state["cycles"], scenario["id"], overlay_sha, workspace) do
        {:ok, reused} ->
          add(acc, Map.merge(reused, %{"cycle_sequence" => base["sequence"]}))

        :none ->
          meta = %{
            "scenario" => scenario["id"],
            "kind" => "base_red",
            "label" => scenario["label"],
            "base_commit" => env.base_commit,
            "overlay_sha256" => overlay_sha,
            "workspace_sha256" => workspace.digest,
            "workspace_rebuilt" => rebuilt?
          }

          run_red(acc, workspace, overlays, scenario, base, env, integrity, meta)
      end
    else
      {:error, reason} ->
        error(acc, base, scenario, "base workspace unavailable: #{reason}")
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  defp run_red(acc, workspace, overlays, scenario, base, env, integrity, meta) do
    case BaseWorkspace.scratch(workspace, overlays) do
      {:ok, dir} ->
        try do
          receipt =
            focused(
              acc.execution,
              base,
              env,
              integrity,
              dir,
              scenario["file_selectors"],
              BaseWorkspace.run_environment(dir),
              meta
            )

          classify_red(acc, receipt, scenario)
        after
          File.rm_rf(dir)
        end

      {:error, reason} ->
        error(acc, base, scenario, reason)
    end
  end

  defp classify_red(acc, receipt, scenario) do
    cond do
      receipt["timed_out"] or receipt["spawn_error"] ->
        receipt = Map.merge(receipt, %{"status" => "error", "red" => false})

        acc
        |> add(receipt)
        |> fail(
          receipt,
          "scenario #{scenario["id"]} red-on-base run did not complete (timeout or infrastructure error; not a red result)"
        )

      receipt["exit_code"] == 0 ->
        receipt = Map.merge(receipt, %{"status" => "failed", "red" => false})

        acc
        |> add(receipt)
        |> fail(
          receipt,
          "scenario #{scenario["id"]}: proof cannot detect the change (its selectors pass on the admission base)"
        )

      true ->
        output = receipt["output"] || ""
        red_kind = if Regex.match?(@load_error, output), do: "load", else: "assertion"

        add(
          acc,
          Map.merge(receipt, %{"status" => "passed", "red" => true, "red_kind" => red_kind})
        )
    end
  end

  defp prior_red(cycles, scenario_id, overlay_sha, workspace) do
    cycles
    |> Enum.reverse()
    |> Enum.flat_map(&List.wrap(&1["proofs"]))
    |> Enum.find_value(:none, fn proof ->
      if proof["scenario"] == scenario_id and proof["kind"] == "base_red" and proof["red"] == true and
           proof["overlay_sha256"] == overlay_sha and
           proof["workspace_sha256"] == workspace.digest do
        origin = proof["reused_from"] || %{"cycle_sequence" => proof["cycle_sequence"]}
        {:ok, Map.put(proof, "reused_from", origin)}
      end
    end)
  end

  defp red_overlays(scenario, base, env, integrity) do
    with {:ok, changes} <- Kogen.Git.tree_changes(env.base_commit, base["candidate_id"], env.root) do
      selector_files =
        expand_selectors(scenario["file_selectors"], base["candidate_id"], env.root)

      surface = integrity["verification_surface"]

      changed_tests =
        for change <- changes,
            test_class?(change["path"], surface),
            not runner_class?(change["path"], surface),
            do: change

      paths =
        (selector_files -- Enum.filter(selector_files, &runner_class?(&1, surface))) ++
          Enum.map(changed_tests, & &1["path"])

      overlays =
        paths
        |> Enum.uniq()
        |> Enum.map(&candidate_overlay(&1, base["candidate_id"], env.root))

      renamed_away =
        for change <- changed_tests,
            change["status"] == "renamed",
            test_class?(change["old_path"], surface),
            do: {change["old_path"], :delete}

      {:ok, Enum.uniq(overlays ++ renamed_away)}
    end
  end

  defp candidate_overlay(path, tree, root) do
    case Kogen.Git.blob(tree, path, root) do
      {:ok, bytes} -> {path, bytes}
      :absent -> {path, :delete}
    end
  end

  defp preservation(acc, scenario, base, env, integrity) do
    files = expand_selectors(scenario["file_selectors"], base["candidate_id"], env.root)

    changed =
      Enum.filter(files, fn path ->
        Kogen.Git.blob(env.base_commit, path, env.root) !=
          Kogen.Git.blob(base["candidate_id"], path, env.root)
      end)

    base_bytes =
      for path <- changed,
          {:ok, bytes} <- [Kogen.Git.blob(env.base_commit, path, env.root)],
          do: {path, bytes}

    if base_bytes == [] do
      acc
    else
      preservation_run(acc, scenario, base, env, integrity, base_bytes)
    end
  end

  defp preservation_run(acc, scenario, base, env, integrity, base_bytes) do
    cache = integrity["base_cache"]

    with {:ok, workspace} <-
           BaseWorkspace.create(env.root, base["candidate_id"], cache, "candidate"),
         {:ok, dir} <- BaseWorkspace.scratch(workspace, base_bytes) do
      try do
        receipt =
          focused(
            acc.execution,
            base,
            env,
            integrity,
            dir,
            Enum.map(base_bytes, &elem(&1, 0)),
            BaseWorkspace.run_environment(dir),
            %{
              "scenario" => scenario["id"],
              "kind" => "base_preservation",
              "label" => scenario["label"],
              "base_commit" => env.base_commit,
              "overlay_sha256" => BaseWorkspace.overlay_digest(base_bytes),
              "changed_selectors" => Enum.map(base_bytes, &elem(&1, 0))
            }
          )

        acc = add(acc, receipt)

        if receipt["status"] == "passed",
          do: acc,
          else:
            fail(
              acc,
              receipt,
              "scenario #{scenario["id"]}: base's bytes of its edited preservation selectors fail on the Candidate"
            )
      after
        File.rm_rf(dir)
        BaseWorkspace.remove(workspace)
      end
    else
      {:error, reason} -> error(acc, base, scenario, reason)
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  defp focused(execution, base, env, integrity, cwd, paths, run_env, meta) do
    argv = Enum.flat_map(integrity["focused_runner"], &if(&1 == "{paths}", do: paths, else: [&1]))
    index = System.unique_integer([:positive])
    name = "cycle-#{base["sequence"]}-proof-#{meta["kind"]}-#{safe(meta["scenario"])}-#{index}"
    log = Path.join(execution.log_root, name <> ".log")
    timeout = Application.get_env(:kogen, :focused_runner_timeout_ms, 1_800_000)

    case VerificationRunner.run(argv, cwd, log, timeout_ms: timeout, env: run_env) do
      {:ok, facts} ->
        meta
        |> Map.merge(%{
          "candidate_id" => base["candidate_id"],
          "attempt_token" => base["attempt_token"],
          "cycle_sequence" => base["sequence"],
          "argv" => argv,
          "status" => VerificationRunner.status(facts),
          "exit_code" => facts["exit_code"],
          "timed_out" => facts["timed_out"],
          "spawn_error" => facts["spawn_error"],
          "cleanup" => facts["cleanup"],
          "started_at" => facts["started_at"],
          "finished_at" => facts["finished_at"],
          "elapsed_ms" => facts["elapsed_ms"],
          "log_path" => Path.relative_to(facts["log_path"], Path.expand(env.root)),
          "log_sha256" => facts["log_sha256"],
          "output" => tail(facts["log_bytes"])
        })

      {:error, reason} ->
        failure = Verification.write_failure_log(execution, base["sequence"], name, reason)

        meta
        |> Map.merge(failure)
        |> Map.merge(%{
          "candidate_id" => base["candidate_id"],
          "attempt_token" => base["attempt_token"],
          "cycle_sequence" => base["sequence"],
          "status" => "error",
          "exit_code" => 1,
          "timed_out" => false,
          "spawn_error" => reason
        })
    end
  end

  defp add(acc, receipt), do: %{acc | proofs: acc.proofs ++ [receipt]}

  defp fail(acc, receipt, reason) do
    %{
      acc
      | failure: %{
          "kind" => "proof",
          "target" => receipt["scenario"],
          "reason" => reason,
          "log_path" => receipt["log_path"],
          "log_sha256" => receipt["log_sha256"],
          "output" => reason <> "\n" <> (receipt["output"] || "")
        }
    }
  end

  defp error(acc, base, scenario, reason) do
    failure =
      Verification.write_failure_log(
        acc.execution,
        base["sequence"],
        "proof-error-#{safe(scenario["id"])}-#{System.unique_integer([:positive])}",
        reason
      )

    receipt =
      Map.merge(failure, %{
        "scenario" => scenario["id"],
        "kind" => "error",
        "status" => "error",
        "cycle_sequence" => base["sequence"]
      })

    acc
    |> add(receipt)
    |> fail(receipt, "scenario #{scenario["id"]} proof run error: #{reason}")
  end

  @doc "Expands directory selectors to the files they hold in `tree`."
  def expand_selectors(selectors, tree, root) do
    case Kogen.Git.tree_files(tree, root) do
      {:ok, files} -> selectors |> Enum.flat_map(&selector_files(&1, files)) |> Enum.uniq()
      _ -> selectors
    end
  end

  defp selector_files(selector, files) do
    clean = String.trim_trailing(selector, "/")

    if clean in files,
      do: [clean],
      else: Enum.filter(files, &String.starts_with?(&1, clean <> "/"))
  end

  @doc "Whether `path` matches the surface's test-class globs."
  def test_class?(path, surface),
    do: Enum.any?(surface["tests"], &VerificationPlan.path_matches?(path, &1))

  @doc "Whether `path` matches the surface's runner-class globs."
  def runner_class?(path, surface),
    do: Enum.any?(surface["runner"], &VerificationPlan.path_matches?(path, &1))

  defp safe(value), do: String.replace(to_string(value), ~r/[^A-Za-z0-9_.-]/, "_")

  defp tail(bytes) when byte_size(bytes) <= 8_192, do: String.replace_invalid(bytes)

  defp tail(bytes),
    do: String.replace_invalid(binary_part(bytes, byte_size(bytes) - 8_192, 8_192))
end

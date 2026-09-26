defmodule Kogen.Build.Contract do
  @moduledoc """
  Parses the immutable scenario contract and validates the bounded messages that
  cross the Developer/Reviewer boundary. This module only validates data; the
  Build state machine owns all transitions and persistence.
  """

  alias Kogen.Build.VerificationPlan
  alias Kogen.Check

  @approved_base ".kogen/intents/approved"
  @scenario_fields ~w(id given when then wrong_result verified_by evidence proof)
  @ownership_fields ~w(paths when_exists owner_after_creation owner_during_operation permitted_mutation validation git_state upgrade_behavior)

  @spec load(String.t()) :: {:ok, map()} | {:error, String.t()}
  def load(slug_or_path) when is_binary(slug_or_path) do
    VerificationPlan.trace("Kogen.Build.Contract.load")
    path = approved_path(slug_or_path)
    scenarios_path = Path.join(path, "scenarios.yaml")

    with :ok <- regular_file(scenarios_path, "scenarios.yaml"),
         {:ok, text} <- File.read(scenarios_path),
         {:ok, scenarios} <- yaml_list(text, "scenarios.yaml"),
         :ok <- validate_scenarios(scenarios),
         {:ok, risks, supplied?} <- load_risks(path, scenario_ids(scenarios)),
         {:ok, added} <- declared_additions(path),
         targets = scenarios |> Enum.flat_map(& &1["verified_by"]) |> Enum.uniq(),
         :ok <- Check.validate_targets(targets -- added) do
      {:ok,
       %{
         scenarios: scenarios,
         risks: risks,
         risks_supplied: supplied?,
         targets: targets,
         text: text
       }}
    end
  end

  def load(_), do: {:error, "Approved contract path is missing or invalid"}

  @spec handoff(String.t(), map(), String.t(), [map()]) :: {:ok, map()} | {:error, String.t()}
  def handoff(text, contract, attempt_token, open_findings)
      when is_binary(text) and is_binary(attempt_token) do
    VerificationPlan.trace("Kogen.Build.Contract.handoff")

    with {:ok, message} <- json_map(text, "Developer handoff"),
         :ok <-
           require_exact_keys(
             message,
             ~w(attempt_token scenarios risks findings),
             "Developer handoff"
           ),
         :ok <-
           match_binding(
             Map.get(message, "attempt_token"),
             attempt_token,
             "Developer handoff attempt_token"
           ),
         {:ok, findings} <- normalized_open_findings(open_findings),
         :ok <- validate_handoff_collections(message, contract, findings) do
      {:ok, message}
    else
      {:error, _reason} = error -> error
      _ -> {:error, "Developer handoff is malformed or incomplete"}
    end
  end

  def handoff(_, _, _, _), do: {:error, "Developer handoff is malformed or incomplete"}

  @doc "Validates a settled provider-denied rehearsal against its catalog authority."
  def rehearsal_evidence(target, rehearsal, evidence)
      when is_map(target) and is_map(rehearsal) and is_map(evidence) do
    required =
      MapSet.new(
        List.wrap(rehearsal["shared_entrypoints"]) ++ List.wrap(rehearsal["trace_assertions"])
      )

    observed = MapSet.new(List.wrap(evidence["observed"]))

    trace_sha256 =
      observed
      |> Enum.sort()
      |> Enum.join("\n")
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    with true <- evidence["schema_version"] == 1,
         true <- evidence["target"] == target["name"],
         true <- evidence["rehearsal_id"] == rehearsal["id"],
         true <- evidence["command"] == rehearsal["command"],
         true <- evidence["status"] == 0,
         true <- MapSet.subset?(required, observed),
         true <- evidence["trace_sha256"] == trace_sha256 do
      :ok
    else
      _ ->
        {:error,
         "rehearsal evidence has foreign authority, incomplete trace, or failed settlement"}
    end
  end

  def rehearsal_evidence(_, _, _),
    do:
      {:error, "rehearsal evidence has foreign authority, incomplete trace, or failed settlement"}

  @spec verdict(map(), map(), map(), [map()]) :: {:ok, map()} | {:error, String.t()}
  def verdict(message, contract, binding, open_findings),
    do: verdict(message, contract, binding, open_findings, [])

  @doc """
  Like `verdict/4` for a Review whose packet carried a verification-surface
  ledger of `ledger_paths`. With a nonempty ledger the verdict must also hold
  `ledger`: exactly one `%{"path", "disposition"}` per ledger path, where the
  disposition is `weakening` or `justified: <scenario-id or finding-id>`.
  Without a ledger the verdict keeps exactly today's keys.
  """
  def verdict(
        message,
        contract,
        %{candidate_id: candidate_id, attempt_token: attempt_token},
        open_findings,
        ledger_paths
      )
      when is_map(message) and is_binary(candidate_id) and is_binary(attempt_token) and
             is_list(ledger_paths) do
    VerificationPlan.trace("Kogen.Build.Contract.verdict")
    keys = ~w(candidate_id attempt_token verdict scenarios dispositions findings)
    keys = if ledger_paths == [], do: keys, else: keys ++ ["ledger"]

    with {:ok, message} <- stringify_map(message),
         :ok <- require_exact_keys(message, keys, "Reviewer verdict"),
         :ok <- validate_ledger(message["ledger"], ledger_paths, contract, open_findings),
         :ok <-
           match_binding(Map.get(message, "candidate_id"), candidate_id, "Reviewer candidate_id"),
         :ok <-
           match_binding(
             Map.get(message, "attempt_token"),
             attempt_token,
             "Reviewer attempt_token"
           ),
         true <- Map.get(message, "verdict") in ["accept", "rework"],
         {:ok, old_findings} <- normalized_open_findings(open_findings),
         :ok <- validate_verdict_collections(message, contract, old_findings),
         :ok <- validate_new_findings(Map.get(message, "findings"), contract),
         :ok <- validate_verdict_whole(message, old_findings) do
      {:ok, message}
    else
      {:error, _reason} = error -> error
      _ -> {:error, "Reviewer verdict is malformed or contradictory"}
    end
  end

  def verdict(_, _, _, _, _), do: {:error, "Reviewer verdict is malformed or contradictory"}

  defp validate_ledger(nil, [], _contract, _open_findings), do: :ok

  defp validate_ledger(ledger, paths, contract, open_findings) when is_list(ledger) do
    ids =
      Enum.map(contract.scenarios, & &1["id"]) ++
        Enum.map(open_findings, &(Map.get(&1, "id") || Map.get(&1, :id)))

    entries_valid? =
      Enum.all?(ledger, fn
        %{"path" => path, "disposition" => disposition} = entry ->
          Enum.sort(Map.keys(entry)) == ["disposition", "path"] and is_binary(path) and
            valid_disposition?(disposition, ids)

        _ ->
          false
      end)

    covered = if entries_valid?, do: Enum.map(ledger, & &1["path"]), else: nil

    if entries_valid? and Enum.sort(covered) == Enum.sort(paths) and
         Enum.uniq(covered) == covered,
       do: :ok,
       else:
         {:error,
          "Reviewer verdict ledger must give exactly one `justified: <scenario-id or finding-id>` or `weakening` disposition per ledger item"}
  end

  defp validate_ledger(_ledger, _paths, _contract, _open_findings),
    do: {:error, "Reviewer verdict ledger is missing or malformed"}

  defp valid_disposition?("weakening", _ids), do: true

  defp valid_disposition?("justified: " <> id, ids), do: String.trim(id) in ids
  defp valid_disposition?(_disposition, _ids), do: false

  # Targets the Intent declares in `catalog_changes.add` do not exist in the
  # admission Makefile yet; the controller checks them in each Candidate.
  defp declared_additions(path) do
    intent_path = Path.join(path, "intent.yaml")

    with {:ok, text} <- File.read(intent_path),
         {:ok, data} when is_map(data) <- YamlElixir.read_from_string(text) do
      case Kogen.Intent.catalog_changes(data) do
        {:ok, %{add: add}} -> {:ok, add}
        {:error, {:invalid, reason}} -> {:error, "intent.yaml #{reason}"}
      end
    else
      _ -> {:ok, []}
    end
  end

  defp approved_path(path) do
    if Path.type(path) == :absolute or String.contains?(path, "/"),
      do: path,
      else: Path.join(@approved_base, path)
  end

  defp load_risks(path, ids) do
    risks_path = Path.join(path, "risks.yaml")

    case File.lstat(risks_path) do
      {:error, :enoent} ->
        {:ok, [], false}

      {:ok, %{type: :regular}} ->
        with {:ok, text} <- File.read(risks_path),
             {:ok, risks} <- yaml_list(text, "risks.yaml", true),
             :ok <- validate_risks(risks, ids) do
          {:ok, risks, true}
        end

      _ ->
        {:error, "risks.yaml missing or invalid: #{risks_path}"}
    end
  end

  defp yaml_list(text, label, allow_empty? \\ false) do
    case YamlElixir.read_from_string(text) do
      {:ok, list} when is_list(list) and (allow_empty? or list != []) -> {:ok, list}
      _ -> {:error, "#{label} missing or invalid"}
    end
  end

  defp validate_scenarios(scenarios) do
    with true <- Enum.all?(scenarios, &scenario?/1),
         ids = scenario_ids(scenarios),
         true <- length(ids) == MapSet.size(MapSet.new(ids)) do
      :ok
    else
      _ -> {:error, "scenarios.yaml missing or invalid"}
    end
  end

  defp scenario?(scenario) when is_map(scenario) do
    Enum.all?(@scenario_fields -- ["verified_by", "proof"], &nonblank?(scenario[&1])) and
      is_list(scenario["verified_by"]) and scenario["verified_by"] != [] and
      Enum.all?(scenario["verified_by"], &nonblank?/1) and proof?(scenario["proof"])
  end

  defp scenario?(_), do: false

  # `base` is optional so contracts written before it keep validating; the
  # controller labels them `unproven-on-base`.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp proof?(proof) when is_map(proof) do
    (Map.keys(proof) -- ["base"]) |> Enum.sort() ==
      Enum.sort(~w(offline paid_target paid_reason affected_paths)) and
      Map.get(proof, "base", "fail") in ["fail", "pass"] and
      is_list(proof["offline"]) and proof["offline"] != [] and
      Enum.all?(proof["offline"], &nonblank?/1) and nonblank?(proof["paid_target"]) and
      nonblank?(proof["paid_reason"]) and is_list(proof["affected_paths"]) and
      proof["affected_paths"] != [] and Enum.all?(proof["affected_paths"], &nonblank?/1)
  end

  defp proof?(_), do: false

  defp scenario_ids(scenarios), do: Enum.map(scenarios, & &1["id"])

  defp validate_risks(risks, ids) do
    risk_ids = Enum.map(risks, fn risk -> if is_map(risk), do: Map.get(risk, "id") end)

    if Enum.all?(risks, &risk?(&1, ids)) and
         length(risk_ids) == MapSet.size(MapSet.new(risk_ids)),
       do: :ok,
       else: {:error, "risks.yaml missing or invalid"}
  end

  defp risk?(risk, ids) when is_map(risk) do
    risk_shape?(risk) and risk_scenario_links?(risk["scenario_ids"], ids) and
      valid_ownership?(Map.get(risk, "ownership"))
  end

  defp risk?(_, _), do: false

  defp risk_shape?(risk) do
    Map.keys(risk) -- ["id", "scenario_ids", "description", "ownership"] == [] and
      nonblank?(risk["id"]) and nonblank?(risk["description"])
  end

  defp risk_scenario_links?(links, ids) when is_list(links) and links != [] do
    Enum.all?(links, &(nonblank?(&1) and &1 in ids)) and
      length(links) == MapSet.size(MapSet.new(links))
  end

  defp risk_scenario_links?(_, _), do: false
  defp valid_ownership?(nil), do: true

  defp valid_ownership?(ownership) when is_list(ownership) and ownership != [],
    do: Enum.all?(ownership, &ownership?/1)

  defp valid_ownership?(_), do: false

  defp ownership?(ownership) when is_map(ownership) do
    Map.keys(ownership) |> Enum.sort() == Enum.sort(@ownership_fields) and
      Enum.all?(@ownership_fields, &nonblank?(ownership[&1]))
  end

  defp ownership?(_), do: false

  defp validate_handoff_collections(message, contract, findings) do
    errors =
      validate_collection(
        message["scenarios"],
        scenario_ids(contract.scenarios),
        "handoff scenarios",
        fn entry, at ->
          entry_errors(
            entry,
            at,
            "handoff scenarios",
            ~w(id status claim implementation evidence),
            [
              value_check("status", &(&1 == "ready"), "expected \"ready\""),
              value_check("claim", &nonblank?/1, "must be nonblank text"),
              refs_check("implementation"),
              refs_check("evidence")
            ]
          )
        end
      ) ++
        validate_collection(
          message["risks"],
          Enum.map(contract.risks, & &1["id"]),
          "handoff risks",
          fn entry, at ->
            checks = [
              value_check("response", &nonblank?/1, "must be nonblank text"),
              refs_check("evidence")
            ]

            errors =
              entry_errors(
                entry,
                at,
                "handoff risks",
                ~w(id scenario_ids response evidence),
                checks
              )

            case Enum.find(contract.risks, &(&1["id"] == entry["id"])) do
              nil ->
                errors

              risk ->
                errors ++
                  field_error(
                    entry,
                    at,
                    "handoff risks",
                    "scenario_ids",
                    &(&1 == risk["scenario_ids"]),
                    "must exactly match the approved risk links"
                  )
            end
          end
        ) ++
        validate_collection(
          message["findings"],
          Enum.map(findings, & &1["id"]),
          "handoff findings",
          fn entry, at ->
            entry_errors(entry, at, "handoff findings", ~w(id status response evidence), [
              value_check(
                "status",
                &(&1 in ["addressed", "blocked", "disputed"]),
                "expected addressed, blocked, or disputed"
              ),
              value_check("response", &nonblank?/1, "must be nonblank text"),
              refs_check("evidence")
            ]) ++
              if(entry["status"] == "blocked",
                do: ["handoff finding remains blocked: #{entry["id"]}"],
                else: []
              )
          end
        )

    errors_result(errors)
  end

  defp validate_verdict_collections(message, contract, old_findings) do
    errors =
      validate_collection(
        message["scenarios"],
        scenario_ids(contract.scenarios),
        "verdict scenarios",
        fn entry, at ->
          entry_errors(entry, at, "verdict scenarios", ~w(id status reason evidence), [
            value_check(
              "status",
              &(&1 in ["satisfied", "needs_rework"]),
              "expected satisfied or needs_rework"
            ),
            value_check("reason", &nonblank?/1, "must be nonblank text"),
            refs_check("evidence")
          ])
        end
      ) ++
        validate_collection(
          message["dispositions"],
          Enum.map(old_findings, & &1["id"]),
          "finding dispositions",
          fn entry, at ->
            entry_errors(entry, at, "finding dispositions", ~w(id status reason evidence), [
              value_check("status", &(&1 in ["closed", "open"]), "expected closed or open"),
              value_check("reason", &nonblank?/1, "must be nonblank text"),
              refs_check("evidence")
            ])
          end
        )

    errors_result(errors)
  end

  defp validate_new_findings(entries, contract) when is_list(entries) do
    ids = scenario_ids(contract.scenarios)

    if Enum.all?(entries, fn entry ->
         is_map(entry) and exact_keys(entry, ~w(scenario_ids reason evidence), "new finding") and
           is_list(entry["scenario_ids"]) and entry["scenario_ids"] != [] and
           Enum.all?(entry["scenario_ids"], &(nonblank?(&1) and &1 in ids)) and
           nonblank?(entry["reason"]) and refs?(entry["evidence"])
       end), do: :ok, else: {:error, "new findings are invalid"}
  end

  defp validate_new_findings(_, _), do: {:error, "new findings are invalid"}

  defp validate_verdict_whole(message, old_findings) do
    state = verdict_state(message, old_findings)

    with :ok <- matching_rework_state(state) do
      verdict_status_valid?(message["verdict"], state)
    end
  end

  defp verdict_state(message, old_findings) do
    open_ids = for %{"id" => id, "status" => "open"} <- message["dispositions"], do: id
    old_by_id = Map.new(old_findings, &{&1["id"], &1})

    %{
      needs_rework:
        for(%{"id" => id, "status" => "needs_rework"} <- message["scenarios"], do: id),
      open_ids: open_ids,
      new_findings: message["findings"],
      unresolved_scenarios: unresolved_scenarios(open_ids, old_by_id, message["findings"])
    }
  end

  defp unresolved_scenarios(open_ids, old_by_id, new_findings) do
    open_ids
    |> Enum.flat_map(&Map.fetch!(old_by_id, &1)["scenario_ids"])
    |> Kernel.++(Enum.flat_map(new_findings, & &1["scenario_ids"]))
    |> MapSet.new()
  end

  defp matching_rework_state(%{needs_rework: needs, unresolved_scenarios: unresolved}) do
    if MapSet.new(needs) == unresolved,
      do: :ok,
      else: {:error, "every unresolved finding and needs_rework scenario must agree"}
  end

  defp verdict_status_valid?("accept", %{needs_rework: [], open_ids: [], new_findings: []}),
    do: :ok

  defp verdict_status_valid?("accept", _),
    do: {:error, "accept cannot leave or create blocking findings"}

  defp verdict_status_valid?("rework", %{needs_rework: []}),
    do: {:error, "rework requires a needs_rework scenario"}

  defp verdict_status_valid?("rework", %{open_ids: [], new_findings: []}),
    do: {:error, "rework requires an open or new finding"}

  defp verdict_status_valid?("rework", _), do: :ok

  defp normalized_open_findings(findings) when is_list(findings) do
    findings
    |> Enum.reduce_while({:ok, []}, fn finding, {:ok, result} ->
      with true <- is_map(finding) and Enum.all?(Map.keys(finding), &is_binary/1),
           {:ok, finding} <- stringify_map(finding),
           true <- nonblank?(finding["id"]),
           true <-
             is_list(finding["scenario_ids"]) and finding["scenario_ids"] != [] and
               Enum.all?(finding["scenario_ids"], &nonblank?/1) do
        {:cont, {:ok, [Map.take(finding, ["id", "scenario_ids"]) | result]}}
      else
        _ -> {:halt, {:error, "open findings are invalid"}}
      end
    end)
    |> case do
      {:ok, normalized} ->
        normalized = Enum.reverse(normalized)
        ids = Enum.map(normalized, & &1["id"])

        if length(ids) == MapSet.size(MapSet.new(ids)),
          do: {:ok, normalized},
          else: {:error, "open findings are invalid"}

      error ->
        error
    end
  end

  defp normalized_open_findings(_), do: {:error, "open findings are invalid"}

  defp validate_collection(entries, _expected_ids, label, _validate) when not is_list(entries),
    do: ["#{label}: expected a list"]

  defp validate_collection(entries, expected_ids, label, validate) do
    positioned = Enum.with_index(entries, 1)

    structural =
      for {entry, position} <- positioned,
          not is_map(entry),
          do: "#{label}: entry at position #{position}: expected an object"

    usable = for {entry, position} <- positioned, is_map(entry), do: {entry, position}
    ids = Enum.map(usable, fn {entry, _position} -> entry["id"] end)

    blank_ids =
      for {entry, position} <- usable,
          not nonblank?(entry["id"]),
          do: "#{label}: entry at position #{position}: field id must be nonblank text"

    missing =
      for id <- expected_ids, id not in ids, do: "#{label}: missing expected ID #{inspect(id)}"

    unexpected =
      for {entry, position} <- usable,
          nonblank?(entry["id"]) and entry["id"] not in expected_ids,
          do: "#{label}: unexpected ID #{inspect(entry["id"])} at position #{position}"

    duplicates =
      usable
      |> Enum.filter(fn {entry, _position} -> nonblank?(entry["id"]) end)
      |> Enum.group_by(fn {entry, _position} -> entry["id"] end, fn {_entry, position} ->
        position
      end)
      |> Enum.filter(fn {_id, positions} -> length(positions) > 1 end)
      |> Enum.sort_by(fn {_id, positions} -> hd(positions) end)
      |> Enum.map(fn {id, positions} ->
        "#{label}: duplicate ID #{inspect(id)} at positions #{Enum.join(positions, ", ")}"
      end)

    entry_errors = Enum.flat_map(usable, fn {entry, position} -> validate.(entry, position) end)
    structural ++ blank_ids ++ missing ++ unexpected ++ duplicates ++ entry_errors
  end

  defp entry_errors(entry, position, label, keys, checks) do
    key_errors =
      if exact_keys(entry, keys, label),
        do: [],
        else: [
          entry_label(label, entry, position) <>
            ": keys are invalid; expected #{Enum.join(keys, ", ")}"
        ]

    key_errors ++ Enum.flat_map(checks, fn check -> check.(entry, position, label) end)
  end

  defp value_check(field, predicate, reason) do
    fn entry, position, label -> field_error(entry, position, label, field, predicate, reason) end
  end

  defp field_error(entry, position, label, field, predicate, reason) do
    if predicate.(entry[field]),
      do: [],
      else: [entry_label(label, entry, position) <> ": field #{field} #{reason}"]
  end

  defp refs_check(field) do
    fn entry, position, label -> reference_errors(entry[field], entry, position, label, field) end
  end

  defp reference_errors(refs, entry, position, label, field) when not is_list(refs),
    do: [entry_label(label, entry, position) <> ": field #{field} expected a nonempty list"]

  defp reference_errors([], entry, position, label, field),
    do: [entry_label(label, entry, position) <> ": field #{field} expected a nonempty list"]

  defp reference_errors(refs, entry, position, label, field) do
    refs
    |> Enum.with_index(1)
    |> Enum.flat_map(fn
      {ref, ref_position} when not is_map(ref) ->
        [entry_label(label, entry, position) <> ": #{field}[#{ref_position}] expected an object"]

      {ref, ref_position} ->
        prefix = entry_label(label, entry, position) <> ": #{field}[#{ref_position}]"

        key_errors =
          if exact_keys(ref, ~w(path locator), "reference"),
            do: [],
            else: [prefix <> ": keys are invalid; expected path, locator"]

        locator_errors =
          if nonblank?(ref["locator"]),
            do: [],
            else: [prefix <> ": field locator must be nonblank text"]

        key_errors ++ locator_errors ++ reference_path_errors(ref["path"], prefix)
    end)
  end

  defp reference_path_errors(path, prefix) when not is_binary(path) or path == "",
    do: [prefix <> ": field path must be nonblank text"]

  defp reference_path_errors(path, prefix) do
    if String.trim(path) == "" do
      [prefix <> ": field path must be nonblank text"]
    else
      path_prefix = prefix <> ", path #{inspect(path)}"

      case local_path_components(path) do
        :error ->
          [path_prefix <> ": unsafe path; expected a relative path without traversal or NUL"]

        {:ok, components} ->
          regular_path_errors(path, components, path_prefix)
      end
    end
  end

  defp regular_path_errors(path, components, prefix) do
    case first_bad_component(components) do
      {:symlink, _component} ->
        [prefix <> ": symlink components are not allowed"]

      {:missing, _component} ->
        [prefix <> ": file does not exist"]

      :ok ->
        case File.lstat(path) do
          {:ok, %{type: :regular}} -> []
          {:ok, %{type: :directory}} -> [prefix <> ": expected a regular file; found directory"]
          {:ok, %{type: type}} -> [prefix <> ": expected a regular file; found #{type}"]
          {:error, :enoent} -> [prefix <> ": file does not exist"]
          {:error, reason} -> [prefix <> ": could not inspect file: #{inspect(reason)}"]
        end
    end
  end

  defp first_bad_component(components) do
    components
    |> Enum.reduce_while({:ok, []}, fn component, {:ok, prefix} ->
      current = prefix ++ [component]

      case File.lstat(Path.join(current)) do
        {:ok, %{type: :symlink}} -> {:halt, {:symlink, component}}
        {:ok, _} -> {:cont, {:ok, current}}
        {:error, :enoent} -> {:halt, {:missing, component}}
        {:error, _} -> {:halt, {:missing, component}}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp entry_label(label, entry, position) do
    if nonblank?(entry["id"]),
      do: "#{label}: entry #{inspect(entry["id"])} at position #{position}",
      else: "#{label}: entry at position #{position}"
  end

  defp errors_result([]), do: :ok
  defp errors_result(errors), do: {:error, Enum.join(errors, "; ")}

  defp refs?(refs) when is_list(refs) and refs != [], do: Enum.all?(refs, &ref?/1)
  defp refs?(_), do: false

  defp ref?(ref) when is_map(ref) do
    exact_keys(ref, ~w(path locator), "reference") and nonblank?(ref["path"]) and
      nonblank?(ref["locator"]) and
      safe_local_regular?(ref["path"])
  end

  defp ref?(_), do: false

  defp safe_local_regular?(path) when is_binary(path) do
    with {:ok, components} <- local_path_components(path),
         :ok <- no_symlink_components(components),
         {:ok, %{type: :regular}} <- File.lstat(path) do
      true
    else
      _ -> false
    end
  end

  defp safe_local_regular?(_), do: false

  defp local_path_components(path) do
    components = Path.split(path)

    if Path.type(path) == :relative and not String.contains?(path, <<0>>) and components != [] and
         not Enum.member?(components, ".."),
       do: {:ok, components},
       else: :error
  end

  defp no_symlink_components(components) do
    components
    |> Enum.reduce_while({:ok, []}, fn component, {:ok, prefix} ->
      current = prefix ++ [component]

      case File.lstat(Path.join(current)) do
        {:ok, %{type: :symlink}} -> {:halt, :error}
        {:ok, _stat} -> {:cont, {:ok, current}}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, _components} -> :ok
      :error -> :error
    end
  end

  defp exact_keys(map, keys, _label) when is_map(map),
    do: Map.keys(map) |> Enum.sort() == Enum.sort(keys)

  defp exact_keys(_, _, _), do: false

  defp require_exact_keys(map, keys, label),
    do: if(exact_keys(map, keys, label), do: :ok, else: {:error, "#{label} keys are invalid"})

  defp match_binding(value, expected, label),
    do:
      if(value == expected,
        do: :ok,
        else: {:error, "#{label} does not match the current binding"}
      )

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""

  defp regular_file(path, label) do
    if File.regular?(path), do: :ok, else: {:error, "#{label} missing or invalid: #{path}"}
  end

  defp json_map(text, label) do
    case Jason.decode(text) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, "#{label} is not JSON object"}
    end
  end

  defp stringify_map(map) when is_map(map) do
    map
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, result} ->
      case stringify_key(key) do
        {:ok, key} -> {:cont, {:ok, Map.put(result, key, stringify_value(value))}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp stringify_map(_), do: :error
  defp stringify_key(key) when is_binary(key), do: {:ok, key}
  defp stringify_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp stringify_key(_), do: :error
  defp stringify_value(value) when is_map(value), do: stringify_map!(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp stringify_map!(map) do
    case stringify_map(map) do
      {:ok, value} -> value
      :error -> map
    end
  end
end

defmodule Kogen.Build.Contract do
  @moduledoc """
  Parses the immutable scenario contract and validates the bounded messages that
  cross the Developer/Reviewer boundary. This module only validates data; the
  Build state machine owns all transitions and persistence.
  """

  alias Kogen.Check

  @approved_base ".kogen/intents/approved"
  @scenario_fields ~w(id given when then wrong_result verified_by evidence)
  @ownership_fields ~w(paths when_exists owner_after_creation owner_during_operation permitted_mutation validation git_state upgrade_behavior)

  @spec load(String.t()) :: {:ok, map()} | {:error, String.t()}
  def load(slug_or_path) when is_binary(slug_or_path) do
    path = approved_path(slug_or_path)
    scenarios_path = Path.join(path, "scenarios.yaml")

    with :ok <- regular_file(scenarios_path, "scenarios.yaml"),
         {:ok, text} <- File.read(scenarios_path),
         {:ok, scenarios} <- yaml_list(text, "scenarios.yaml"),
         :ok <- validate_scenarios(scenarios),
         {:ok, risks, supplied?} <- load_risks(path, scenario_ids(scenarios)),
         targets = scenarios |> Enum.flat_map(& &1["verified_by"]) |> Enum.uniq(),
         :ok <- Check.validate_targets(targets) do
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
         :ok <- validate_handoff_scenarios(Map.get(message, "scenarios"), contract),
         :ok <- validate_handoff_risks(Map.get(message, "risks"), contract),
         :ok <- validate_handoff_findings(Map.get(message, "findings"), findings) do
      {:ok, message}
    else
      {:error, _reason} = error -> error
      _ -> {:error, "Developer handoff is malformed or incomplete"}
    end
  end

  def handoff(_, _, _, _), do: {:error, "Developer handoff is malformed or incomplete"}

  @spec verdict(map(), map(), map(), [map()]) :: {:ok, map()} | {:error, String.t()}
  def verdict(
        message,
        contract,
        %{candidate_id: candidate_id, attempt_token: attempt_token},
        open_findings
      )
      when is_map(message) and is_binary(candidate_id) and is_binary(attempt_token) do
    with {:ok, message} <- stringify_map(message),
         :ok <-
           require_exact_keys(
             message,
             ~w(candidate_id attempt_token verdict scenarios dispositions findings),
             "Reviewer verdict"
           ),
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
         :ok <- validate_verdict_scenarios(Map.get(message, "scenarios"), contract),
         :ok <- validate_dispositions(Map.get(message, "dispositions"), old_findings),
         :ok <- validate_new_findings(Map.get(message, "findings"), contract),
         :ok <- validate_verdict_whole(message, old_findings) do
      {:ok, message}
    else
      {:error, _reason} = error -> error
      _ -> {:error, "Reviewer verdict is malformed or contradictory"}
    end
  end

  def verdict(_, _, _, _), do: {:error, "Reviewer verdict is malformed or contradictory"}

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
    Enum.all?(@scenario_fields -- ["verified_by"], &nonblank?(scenario[&1])) and
      is_list(scenario["verified_by"]) and scenario["verified_by"] != [] and
      Enum.all?(scenario["verified_by"], &nonblank?/1)
  end

  defp scenario?(_), do: false
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

  defp validate_handoff_scenarios(entries, contract) when is_list(entries) do
    validate_exact(entries, scenario_ids(contract.scenarios), fn entry ->
      exact_keys(entry, ~w(id status claim implementation evidence), "handoff scenario") and
        Map.get(entry, "status") == "ready" and nonblank?(entry["claim"]) and
        refs?(entry["implementation"]) and refs?(entry["evidence"])
    end)
  end

  defp validate_handoff_scenarios(_, _), do: {:error, "handoff scenarios are invalid"}

  defp validate_handoff_risks(entries, contract) when is_list(entries) do
    validate_exact(entries, Enum.map(contract.risks, & &1["id"]), fn entry ->
      exact_keys(entry, ~w(id scenario_ids response evidence), "handoff risk") and
        nonblank?(entry["response"]) and refs?(entry["evidence"]) and
        case Enum.find(contract.risks, &(&1["id"] == entry["id"])) do
          nil -> false
          risk -> entry["scenario_ids"] == risk["scenario_ids"]
        end
    end)
  end

  defp validate_handoff_risks(_, _), do: {:error, "handoff risks are invalid"}

  defp validate_handoff_findings(entries, findings) when is_list(entries) do
    with :ok <-
           validate_exact(entries, Enum.map(findings, & &1["id"]), fn entry ->
             exact_keys(entry, ~w(id status response evidence), "handoff finding") and
               Map.get(entry, "status") in ["addressed", "blocked", "disputed"] and
               nonblank?(entry["response"]) and refs?(entry["evidence"])
           end),
         nil <- Enum.find(entries, &(Map.get(&1, "status") == "blocked")) do
      :ok
    else
      %{"id" => id} -> {:error, "handoff finding remains blocked: #{id}"}
      {:error, _reason} = error -> error
    end
  end

  defp validate_handoff_findings(_, _), do: {:error, "handoff findings are invalid"}

  defp validate_verdict_scenarios(entries, contract) when is_list(entries) do
    validate_exact(entries, scenario_ids(contract.scenarios), fn entry ->
      exact_keys(entry, ~w(id status reason evidence), "verdict scenario") and
        Map.get(entry, "status") in ["satisfied", "needs_rework"] and
        nonblank?(entry["reason"]) and refs?(entry["evidence"])
    end)
  end

  defp validate_verdict_scenarios(_, _), do: {:error, "verdict scenarios are invalid"}

  defp validate_dispositions(entries, old_findings) when is_list(entries) do
    validate_exact(entries, Enum.map(old_findings, & &1["id"]), fn entry ->
      exact_keys(entry, ~w(id status reason evidence), "finding disposition") and
        Map.get(entry, "status") in ["closed", "open"] and nonblank?(entry["reason"]) and
        refs?(entry["evidence"])
    end)
  end

  defp validate_dispositions(_, _), do: {:error, "finding dispositions are invalid"}

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

  defp validate_exact(entries, expected_ids, valid?) do
    ids = Enum.map(entries, &if(is_map(&1), do: Map.get(&1, "id"), else: nil))

    if Enum.sort(ids) == Enum.sort(expected_ids) and length(ids) == MapSet.size(MapSet.new(ids)) and
         Enum.all?(entries, valid?),
       do: :ok,
       else:
         {:error,
          "coverage is missing, duplicate, or invalid for IDs: #{Enum.join(expected_ids, ", ")}"}
  end

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

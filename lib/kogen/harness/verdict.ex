defmodule Kogen.Harness.Verdict do
  @moduledoc "The harness-independent Reviewer verdict schema, validator and receipt log."

  # Lookaround-free (Codex `--output-schema` rejects `(?=`, `(?!`, `(?<=`,
  # `(?<!` with 400 invalid_json_schema): rejects a leading `/`, `..`, `.` and
  # empty segments. See evidence/probe-codex-verdict-schema.
  @evidence_path_pattern "^(?:[^/.][^/]*|\\.[^/.][^/]*)(?:/(?:[^/.][^/]*|\\.[^/.][^/]*))*$"
  @evidence_path_regex Regex.compile!(@evidence_path_pattern)

  # A review-packet pointer this evidence cites, or `null` when none applies.
  @receipt_pattern "^/receipts/[0-9]+(/.*)?$"
  @receipt_regex Regex.compile!(@receipt_pattern)

  @evidence_schema %{
    "type" => "array",
    "items" => %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "minLength" => 1,
          "description" =>
            "Existing regular repository-relative file. For a missing-file defect cite an existing requirement/test/evidence file; describe the absent file in reason and locator, never here."
        },
        "locator" => %{"type" => "string", "minLength" => 1}
      },
      "required" => ["path", "locator"],
      "additionalProperties" => false
    }
  }

  # The per-launch evidence item schema (`per-launch-verdict-schema`): a
  # lookaround-free `path` pattern, and a separate required `receipt` field
  # (`null`, or a review-packet pointer), because an unconstrained free-form
  # `receipt` string gets filled with quotes instead (Claude probe).
  @per_launch_evidence_schema %{
    "type" => "array",
    "items" => %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "minLength" => 1,
          "pattern" => @evidence_path_pattern,
          "description" =>
            "Existing regular repository-relative file. No leading '/', no '..' and no empty segments. For a missing-file defect cite an existing requirement/test/evidence file; describe the absent file in reason and locator, never here."
        },
        "locator" => %{"type" => "string", "minLength" => 1},
        "receipt" => %{
          "type" => ["string", "null"],
          "pattern" => @receipt_pattern,
          "description" =>
            "The review-packet receipt pointer this evidence cites (for example `/receipts/3`), when your verdict schema provides it; otherwise `null`."
        }
      },
      "required" => ["path", "locator", "receipt"],
      "additionalProperties" => false
    }
  }

  @verdict_schema Jason.encode!(%{
                    "type" => "object",
                    "properties" => %{
                      "candidate_id" => %{"type" => "string", "minLength" => 1},
                      "attempt_token" => %{"type" => "string", "minLength" => 1},
                      "verdict" => %{"type" => "string", "enum" => ["accept", "rework"]},
                      "scenarios" => %{
                        "type" => "array",
                        "items" => %{
                          "type" => "object",
                          "properties" => %{
                            "id" => %{"type" => "string", "minLength" => 1},
                            "status" => %{
                              "type" => "string",
                              "enum" => ["satisfied", "needs_rework"]
                            },
                            "reason" => %{"type" => "string", "minLength" => 1},
                            "evidence" => @evidence_schema
                          },
                          "required" => ["id", "status", "reason", "evidence"],
                          "additionalProperties" => false
                        }
                      },
                      "dispositions" => %{
                        "type" => "array",
                        "items" => %{
                          "type" => "object",
                          "properties" => %{
                            "id" => %{"type" => "string", "minLength" => 1},
                            "status" => %{"type" => "string", "enum" => ["closed", "open"]},
                            "reason" => %{"type" => "string", "minLength" => 1},
                            "evidence" => @evidence_schema
                          },
                          "required" => ["id", "status", "reason", "evidence"],
                          "additionalProperties" => false
                        }
                      },
                      "findings" => %{
                        "type" => "array",
                        "items" => %{
                          "type" => "object",
                          "properties" => %{
                            "scenario_ids" => %{
                              "type" => "array",
                              "minItems" => 1,
                              "items" => %{"type" => "string", "minLength" => 1}
                            },
                            "reason" => %{"type" => "string", "minLength" => 1},
                            "evidence" => @evidence_schema
                          },
                          "required" => ["scenario_ids", "reason", "evidence"],
                          "additionalProperties" => false
                        }
                      }
                    },
                    "required" => [
                      "candidate_id",
                      "attempt_token",
                      "verdict",
                      "scenarios",
                      "dispositions",
                      "findings"
                    ],
                    "additionalProperties" => false
                  })

  @doc "The encoded JSON Schema every Reviewer verdict must satisfy."
  def schema, do: @verdict_schema

  @doc """
  The schema for one Reviewer launch. Without ledger paths it is exactly
  `schema/0`. With a nonempty verification-surface ledger it adds a required
  `ledger` array holding one `path`/`disposition` item per ledger path.
  """
  def schema([]), do: @verdict_schema

  def schema(ledger_paths) when is_list(ledger_paths) do
    decoded = Jason.decode!(@verdict_schema)

    ledger = %{
      "type" => "array",
      "minItems" => length(ledger_paths),
      "maxItems" => length(ledger_paths),
      "items" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "enum" => ledger_paths},
          "disposition" => %{
            "type" => "string",
            "pattern" => "^(weakening|justified: \\S.*)$",
            "description" =>
              "`weakening`, or `justified: <scenario-id or finding-id>` naming what justifies the change."
          }
        },
        "required" => ["path", "disposition"],
        "additionalProperties" => false
      }
    }

    decoded
    |> put_in(["properties", "ledger"], ledger)
    |> Map.update!("required", &(&1 ++ ["ledger"]))
    |> Jason.encode!()
  end

  @doc """
  The schema for one Reviewer launch (`per-launch-verdict-schema`), built from
  this launch's `ledger_paths` (see `schema/1`) and the Approved Intent's
  `scenario_ids`. With a nonempty `scenario_ids` the `scenarios` array gets
  `minItems` = `maxItems` = the scenario count, each `id` constrained to an
  `enum` of those ids, and every evidence item across `scenarios`,
  `dispositions` and `findings` gets the lookaround-free `path` pattern and
  the separate required `receipt` field. An empty `scenario_ids` is exactly
  `schema/1`.
  """
  def schema(ledger_paths, []) when is_list(ledger_paths), do: schema(ledger_paths)

  def schema(ledger_paths, scenario_ids)
      when is_list(ledger_paths) and is_list(scenario_ids) do
    ledger_paths
    |> schema()
    |> Jason.decode!()
    |> put_in(["properties", "scenarios", "minItems"], length(scenario_ids))
    |> put_in(["properties", "scenarios", "maxItems"], length(scenario_ids))
    |> put_in(["properties", "scenarios", "items", "properties", "id", "enum"], scenario_ids)
    |> replace_evidence_schemas()
    |> Jason.encode!()
  end

  defp replace_evidence_schemas(decoded) do
    Enum.reduce(["scenarios", "dispositions", "findings"], decoded, fn key, acc ->
      put_in(
        acc,
        ["properties", key, "items", "properties", "evidence"],
        @per_launch_evidence_schema
      )
    end)
  end

  @doc """
  Decodes and validates a verdict message. Returns what `validate/2` returns;
  a message that is not JSON is `{:error, [errors]}` too.
  """
  def parse(output, ledger_or_opts \\ false)

  def parse(output, ledger_or_opts) when is_binary(output) do
    case Jason.decode(String.trim(output)) do
      {:ok, json} -> validate(json, ledger_or_opts)
      _ -> {:error, [err("", "type: expected a JSON document")]}
    end
  end

  def parse(_output, _ledger_or_opts), do: {:error, [err("", "type: expected a JSON document")]}

  @doc """
  Validates an already decoded verdict value and returns `{:ok, verdict}` or
  `{:error, [errors]}`, each error naming the JSON pointer and the rule. A
  map of `:ledger?`, `:ledger_paths` and `:scenario_ids` validates against
  the per-launch schema (`validate_launch/2`). A bare `ledger?` boolean
  validates the legacy shape of `schema/1`, for a launch that builds no
  per-launch schema: no evidence `receipt` field, no `path` pattern and no
  scenario-id constraint.
  """
  def validate(json, ledger_or_opts \\ false)

  def validate(json, opts) when is_map(opts), do: validate_launch(json, opts)

  def validate(json, ledger?) when is_boolean(ledger?),
    do: validate_launch(json, %{ledger?: ledger?, shape: :legacy})

  @doc """
  Validates an already decoded verdict value against the schema built for one
  Reviewer launch (`schema/2`). `opts` carries `:ledger?` (default `false`),
  `:ledger_paths` (default `[]`) and `:scenario_ids` (default `[]`, which
  skips the scenario count/enum checks). Returns `{:ok, %{verdict:,
  findings:, response:}}` or `{:error, [errors]}`, each error a
  `%{pointer:, rule:}` naming the JSON pointer of the offending value and the
  violated rule.
  """
  def validate_launch(json, opts) when is_map(opts) do
    ledger? = Map.get(opts, :ledger?, false)
    ledger_paths = Map.get(opts, :ledger_paths, [])
    scenario_ids = Map.get(opts, :scenario_ids, [])
    shape = Map.get(opts, :shape, :launch)

    case launch_errors(json, {ledger?, ledger_paths}, scenario_ids, shape) do
      [] -> {:ok, %{verdict: json["verdict"], findings: json["findings"], response: json}}
      errors -> {:error, errors}
    end
  end

  defp launch_errors(json, {ledger?, ledger_paths}, scenario_ids, shape) when is_map(json) do
    keys = verdict_keys(ledger?)

    if Map.keys(json) |> Enum.sort() == keys do
      scalar_errors(json) ++
        scenarios_errors(json["scenarios"], scenario_ids, shape) ++
        dispositions_errors(json["dispositions"], shape) ++
        findings_errors(json["findings"], shape) ++
        ledger_errors(json["ledger"], ledger?, ledger_paths, shape)
    else
      [err("", "additionalProperties/required: expected exactly #{inspect(keys)}")]
    end
  end

  defp launch_errors(_json, _ledger, _scenario_ids, _shape),
    do: [err("", "type: expected an object")]

  defp scalar_errors(json) do
    []
    |> add_unless(nonblank?(json["candidate_id"]), "/candidate_id", "minLength: must be nonblank")
    |> add_unless(
      nonblank?(json["attempt_token"]),
      "/attempt_token",
      "minLength: must be nonblank"
    )
    |> add_unless(
      json["verdict"] in ["accept", "rework"],
      "/verdict",
      "enum: expected accept or rework"
    )
  end

  defp add_unless(errors, true, _pointer, _rule), do: errors
  defp add_unless(errors, false, pointer, rule), do: errors ++ [err(pointer, rule)]

  defp scenarios_errors(scenarios, scenario_ids, shape) when is_list(scenarios) do
    count_errors =
      if scenario_ids == [] or length(scenarios) == length(scenario_ids) do
        []
      else
        [
          err(
            "/scenarios",
            "minItems/maxItems: expected #{length(scenario_ids)} items, got #{length(scenarios)}"
          )
        ]
      end

    missing_errors =
      if scenario_ids == [] do
        []
      else
        present_ids = Enum.map(scenarios, & &1["id"])

        Enum.map(scenario_ids -- present_ids, fn id ->
          err("/scenarios", "required: missing scenario id #{inspect(id)}")
        end)
      end

    item_errors =
      scenarios
      |> Enum.with_index()
      |> Enum.flat_map(fn {scenario, i} ->
        scenario_item_errors(scenario, i, scenario_ids, shape)
      end)

    count_errors ++ missing_errors ++ item_errors
  end

  defp scenarios_errors(_scenarios, _scenario_ids, _shape),
    do: [err("/scenarios", "type: expected an array")]

  defp scenario_item_errors(scenario, i, scenario_ids, shape) when is_map(scenario) do
    pointer = "/scenarios/#{i}"
    keys = ~w(evidence id reason status)

    key_errors =
      if Map.keys(scenario) |> Enum.sort() == keys,
        do: [],
        else: [err(pointer, "additionalProperties/required: expected exactly #{inspect(keys)}")]

    id_errors =
      if scenario_ids == [] or scenario["id"] in scenario_ids,
        do: [],
        else: [
          err(pointer <> "/id", "enum: #{inspect(scenario["id"])} is not a declared scenario id")
        ]

    status_errors =
      if scenario["status"] in ["satisfied", "needs_rework"],
        do: [],
        else: [err(pointer <> "/status", "enum: expected satisfied or needs_rework")]

    reason_errors =
      if nonblank?(scenario["reason"]),
        do: [],
        else: [err(pointer <> "/reason", "minLength: must be nonblank")]

    key_errors ++
      id_errors ++
      status_errors ++
      reason_errors ++ evidence_errors(scenario["evidence"], pointer <> "/evidence", shape)
  end

  defp scenario_item_errors(_scenario, i, _scenario_ids, _shape),
    do: [err("/scenarios/#{i}", "type: expected an object")]

  defp dispositions_errors(dispositions, shape) when is_list(dispositions) do
    dispositions
    |> Enum.with_index()
    |> Enum.flat_map(fn {disposition, i} -> disposition_item_errors(disposition, i, shape) end)
  end

  defp dispositions_errors(_dispositions, _shape),
    do: [err("/dispositions", "type: expected an array")]

  defp disposition_item_errors(disposition, i, shape) when is_map(disposition) do
    pointer = "/dispositions/#{i}"
    keys = ~w(evidence id reason status)

    key_errors =
      if Map.keys(disposition) |> Enum.sort() == keys,
        do: [],
        else: [err(pointer, "additionalProperties/required: expected exactly #{inspect(keys)}")]

    id_errors =
      if nonblank?(disposition["id"]),
        do: [],
        else: [err(pointer <> "/id", "minLength: must be nonblank")]

    status_errors =
      if disposition["status"] in ["closed", "open"],
        do: [],
        else: [err(pointer <> "/status", "enum: expected closed or open")]

    reason_errors =
      if nonblank?(disposition["reason"]),
        do: [],
        else: [err(pointer <> "/reason", "minLength: must be nonblank")]

    key_errors ++
      id_errors ++
      status_errors ++
      reason_errors ++ evidence_errors(disposition["evidence"], pointer <> "/evidence", shape)
  end

  defp disposition_item_errors(_disposition, i, _shape),
    do: [err("/dispositions/#{i}", "type: expected an object")]

  defp findings_errors(findings, shape) when is_list(findings) do
    findings
    |> Enum.with_index()
    |> Enum.flat_map(fn {finding, i} -> finding_item_errors(finding, i, shape) end)
  end

  defp findings_errors(_findings, _shape), do: [err("/findings", "type: expected an array")]

  defp finding_item_errors(finding, i, shape) when is_map(finding) do
    pointer = "/findings/#{i}"
    keys = ~w(evidence reason scenario_ids)

    key_errors =
      if Map.keys(finding) |> Enum.sort() == keys,
        do: [],
        else: [err(pointer, "additionalProperties/required: expected exactly #{inspect(keys)}")]

    ids = finding["scenario_ids"]

    ids_errors =
      cond do
        not is_list(ids) ->
          [err(pointer <> "/scenario_ids", "type: expected an array")]

        ids == [] ->
          [err(pointer <> "/scenario_ids", "minItems: must be nonempty")]

        not Enum.all?(ids, &nonblank?/1) ->
          [err(pointer <> "/scenario_ids", "minLength: every item must be nonblank")]

        true ->
          []
      end

    reason_errors =
      if nonblank?(finding["reason"]),
        do: [],
        else: [err(pointer <> "/reason", "minLength: must be nonblank")]

    key_errors ++
      ids_errors ++
      reason_errors ++ evidence_errors(finding["evidence"], pointer <> "/evidence", shape)
  end

  defp finding_item_errors(_finding, i, _shape),
    do: [err("/findings/#{i}", "type: expected an object")]

  defp evidence_errors(evidence, pointer, shape) when is_list(evidence) do
    evidence
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, i} -> evidence_item_errors(item, pointer <> "/#{i}", shape) end)
  end

  defp evidence_errors(_evidence, pointer, _shape), do: [err(pointer, "type: expected an array")]

  # The legacy shape (`schema/1`): exactly `path` and `locator`, both nonblank.
  defp evidence_item_errors(item, pointer, :legacy) when is_map(item) do
    keys = ~w(locator path)

    key_errors =
      if Map.keys(item) |> Enum.sort() == keys,
        do: [],
        else: [err(pointer, "additionalProperties/required: expected exactly #{inspect(keys)}")]

    key_errors ++
      Enum.flat_map(keys, fn key ->
        if nonblank?(item[key]),
          do: [],
          else: [err(pointer <> "/" <> key, "minLength: must be nonblank")]
      end)
  end

  defp evidence_item_errors(item, pointer, :launch) when is_map(item) do
    keys = ~w(locator path receipt)

    key_errors =
      if Map.keys(item) |> Enum.sort() == keys,
        do: [],
        else: [err(pointer, "additionalProperties/required: expected exactly #{inspect(keys)}")]

    locator_errors =
      if nonblank?(item["locator"]),
        do: [],
        else: [err(pointer <> "/locator", "minLength: must be nonblank")]

    key_errors ++
      locator_errors ++
      evidence_path_errors(item["path"], pointer <> "/path") ++
      evidence_receipt_errors(item["receipt"], pointer <> "/receipt")
  end

  defp evidence_item_errors(_item, pointer, _shape),
    do: [err(pointer, "type: expected an object")]

  defp evidence_path_errors(path, pointer) when is_binary(path) and path != "" do
    if Regex.match?(@evidence_path_regex, path),
      do: [],
      else: [
        err(
          pointer,
          "pattern: must be a repository-relative path with no leading '/', no '..' and no empty segments"
        )
      ]
  end

  defp evidence_path_errors(_path, pointer), do: [err(pointer, "minLength: must be nonblank")]

  defp evidence_receipt_errors(nil, _pointer), do: []

  defp evidence_receipt_errors(receipt, pointer) when is_binary(receipt) do
    if Regex.match?(@receipt_regex, receipt),
      do: [],
      else: [err(pointer, "pattern: must be null or match #{@receipt_pattern}")]
  end

  defp evidence_receipt_errors(_receipt, pointer),
    do: [err(pointer, "type: expected null or a string")]

  defp ledger_errors(nil, false, [], _shape), do: []

  # The legacy shape knows no ledger paths: each item is exactly a nonblank
  # `path` and `disposition`.
  defp ledger_errors(ledger, true, _ledger_paths, :legacy) when is_list(ledger) do
    ledger
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {%{"path" => path, "disposition" => disposition} = item, i} ->
        if Map.keys(item) |> Enum.sort() == ["disposition", "path"] and nonblank?(path) and
             nonblank?(disposition),
           do: [],
           else: [
             err(
               "/ledger/#{i}",
               "additionalProperties/minLength: expected nonblank path, disposition"
             )
           ]

      {_item, i} ->
        [err("/ledger/#{i}", "type: expected an object with path and disposition")]
    end)
  end

  defp ledger_errors(ledger, true, ledger_paths, :launch) when is_list(ledger) do
    count_errors =
      if length(ledger) == length(ledger_paths),
        do: [],
        else: [err("/ledger", "minItems/maxItems: expected #{length(ledger_paths)} items")]

    item_errors =
      ledger
      |> Enum.with_index()
      |> Enum.flat_map(fn {item, i} -> ledger_item_errors(item, i, ledger_paths) end)

    covered = Enum.map(ledger, & &1["path"])

    duplicate_errors =
      if Enum.uniq(covered) == covered,
        do: [],
        else: [err("/ledger", "uniqueItems: every ledger path must be covered exactly once")]

    missing_errors =
      Enum.map(ledger_paths -- covered, fn path ->
        err("/ledger", "required: missing ledger disposition for #{inspect(path)}")
      end)

    count_errors ++ item_errors ++ duplicate_errors ++ missing_errors
  end

  defp ledger_errors(_ledger, true, _ledger_paths, _shape),
    do: [err("/ledger", "type/required: expected an array")]

  defp ledger_errors(_ledger, false, _ledger_paths, _shape), do: []

  defp ledger_item_errors(%{"path" => path, "disposition" => disposition} = item, i, ledger_paths) do
    pointer = "/ledger/#{i}"

    key_errors =
      if Map.keys(item) |> Enum.sort() == ["disposition", "path"],
        do: [],
        else: [err(pointer, "additionalProperties/required: expected exactly path, disposition")]

    path_errors =
      if path in ledger_paths,
        do: [],
        else: [err(pointer <> "/path", "enum: #{inspect(path)} is not a ledger path")]

    disposition_errors =
      if is_binary(disposition) and Regex.match?(~r/^(weakening|justified: \S.*)$/, disposition),
        do: [],
        else: [
          err(
            pointer <> "/disposition",
            "pattern: expected `weakening` or `justified: <id>`"
          )
        ]

    key_errors ++ path_errors ++ disposition_errors
  end

  defp ledger_item_errors(_item, i, _ledger_paths),
    do: [err("/ledger/#{i}", "type: expected an object with path and disposition")]

  # String-keyed: this list is recorded verbatim into the scenario tracking
  # record (via `stop/3`'s malformed-verdict details), which requires string
  # keys at every level.
  defp err(pointer, rule), do: %{"pointer" => pointer, "rule" => rule}

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""

  defp verdict_keys(false) do
    ["attempt_token", "candidate_id", "dispositions", "findings", "scenarios", "verdict"]
  end

  defp verdict_keys(true), do: Enum.sort(["ledger" | verdict_keys(false)])

  @doc "The lookaround-free evidence `path` pattern the per-launch schema uses."
  def evidence_path_pattern, do: @evidence_path_pattern

  @doc "The review-packet `receipt` pointer pattern the per-launch schema uses."
  def receipt_pattern, do: @receipt_pattern

  @doc "Retains the Reviewer's verdict and receipt when a raw log directory is configured."
  def persist(message, session_id, extra \\ %{}) do
    case System.get_env("KOGEN_RAW_LOG_DIR") do
      nil ->
        :ok

      dir ->
        File.mkdir_p!(dir)

        name =
          "reviewer-verdict-#{System.pid()}-#{System.unique_integer([:positive, :monotonic])}.json"

        File.write!(Path.join(dir, name), message)

        receipt =
          message
          |> Jason.decode!()
          |> Map.put("session_id", session_id)
          |> Map.merge(extra)
          |> Jason.encode!()

        File.write!(Path.join(dir, "reviewer-verdicts.jsonl"), receipt <> "\n", [:append])
    end
  end
end

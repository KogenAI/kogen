defmodule Kogen.Harness.Verdict do
  @moduledoc "The harness-independent Reviewer verdict schema, validator and receipt log."

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

  @doc "Decodes and validates a verdict message."
  def parse(output) when is_binary(output) do
    case Jason.decode(String.trim(output)) do
      {:ok, json} -> validate(json)
      _ -> :error
    end
  end

  def parse(_output), do: :error

  @doc "Validates an already decoded verdict value."
  def validate(json) do
    if valid_verdict?(json) do
      {:ok, %{verdict: json["verdict"], findings: json["findings"], response: json}}
    else
      :error
    end
  end

  defp valid_verdict?(json) when is_map(json) do
    Map.keys(json) |> Enum.sort() == verdict_keys() and
      nonblank?(json["candidate_id"]) and
      nonblank?(json["attempt_token"]) and
      json["verdict"] in ["accept", "rework"] and
      valid_scenarios?(json["scenarios"]) and
      valid_dispositions?(json["dispositions"]) and
      valid_findings?(json["findings"])
  end

  defp valid_verdict?(_json), do: false

  defp valid_scenarios?(scenarios) when is_list(scenarios) do
    Enum.all?(scenarios, fn
      %{"id" => id, "status" => status, "reason" => reason, "evidence" => evidence} = scenario ->
        Map.keys(scenario) |> Enum.sort() == ["evidence", "id", "reason", "status"] and
          nonblank?(id) and status in ["satisfied", "needs_rework"] and nonblank?(reason) and
          valid_evidence?(evidence)

      _ ->
        false
    end)
  end

  defp valid_scenarios?(_scenarios), do: false

  defp valid_dispositions?(dispositions) when is_list(dispositions) do
    Enum.all?(dispositions, fn
      %{"id" => id, "status" => status, "reason" => reason, "evidence" => evidence} = disposition ->
        Map.keys(disposition) |> Enum.sort() == ["evidence", "id", "reason", "status"] and
          nonblank?(id) and status in ["closed", "open"] and nonblank?(reason) and
          valid_evidence?(evidence)

      _ ->
        false
    end)
  end

  defp valid_dispositions?(_dispositions), do: false

  defp valid_findings?(findings) when is_list(findings) do
    Enum.all?(findings, fn
      %{"scenario_ids" => scenario_ids, "reason" => reason, "evidence" => evidence} = finding ->
        Map.keys(finding) |> Enum.sort() == ["evidence", "reason", "scenario_ids"] and
          is_list(scenario_ids) and scenario_ids != [] and Enum.all?(scenario_ids, &nonblank?/1) and
          nonblank?(reason) and valid_evidence?(evidence)

      _ ->
        false
    end)
  end

  defp valid_findings?(_findings), do: false

  defp valid_evidence?(evidence) when is_list(evidence) do
    Enum.all?(evidence, fn
      %{"path" => path, "locator" => locator} = reference ->
        Map.keys(reference) |> Enum.sort() == ["locator", "path"] and nonblank?(path) and
          nonblank?(locator)

      _ ->
        false
    end)
  end

  defp valid_evidence?(_evidence), do: false

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""

  defp verdict_keys do
    ["attempt_token", "candidate_id", "dispositions", "findings", "scenarios", "verdict"]
  end

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

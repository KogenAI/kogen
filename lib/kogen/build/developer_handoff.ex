defmodule Kogen.Build.DeveloperHandoff do
  @moduledoc false

  @spec schema(map(), String.t(), [map()]) :: {:ok, binary()} | {:error, String.t()}
  def schema(contract, attempt_token, open_findings)
      when is_map(contract) and is_binary(attempt_token) and is_list(open_findings) do
    with true <- String.trim(attempt_token) != "",
         {:ok, scenario_ids} <- ids(contract.scenarios),
         {:ok, risk_ids} <- ids(contract.risks),
         {:ok, finding_ids} <- ids(open_findings) do
      Jason.encode(
        object(%{
          "attempt_token" => %{"type" => "string", "enum" => [attempt_token]},
          "scenarios" =>
            collection(
              scenario_ids,
              object(%{
                "id" => id_schema(scenario_ids),
                "status" => %{"type" => "string", "enum" => ["ready", "incomplete"]},
                "claim" => text(),
                "implementation" => references(),
                "evidence" => references()
              })
            ),
          "risks" =>
            collection(
              risk_ids,
              object(%{
                "id" => id_schema(risk_ids),
                "scenario_ids" => %{
                  "type" => "array",
                  "items" => id_schema(scenario_ids),
                  "minItems" => 1,
                  "maxItems" => length(scenario_ids)
                },
                "response" => text(),
                "evidence" => references()
              })
            ),
          "findings" =>
            collection(
              finding_ids,
              object(%{
                "id" => id_schema(finding_ids),
                "status" => %{
                  "type" => "string",
                  "enum" => ["addressed", "blocked", "disputed"]
                },
                "response" => text(),
                "evidence" => references()
              })
            )
        })
      )
    else
      false -> {:error, "Developer handoff schema requires a nonblank attempt token"}
      {:error, _reason} = error -> error
    end
  end

  def schema(_contract, _attempt_token, _open_findings),
    do: {:error, "Developer handoff schema requires the current contract and findings"}

  defp ids(entries) when is_list(entries) do
    values = Enum.map(entries, &Map.get(&1, "id"))

    if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")),
      do: {:ok, values},
      else: {:error, "Developer handoff schema received invalid contract IDs"}
  end

  defp ids(_entries), do: {:error, "Developer handoff schema received invalid collections"}

  defp collection([], item),
    do: %{"type" => "array", "minItems" => 0, "maxItems" => 0, "items" => item}

  defp collection(ids, item),
    do: %{
      "type" => "array",
      "minItems" => length(ids),
      "maxItems" => length(ids),
      "items" => item
    }

  defp object(properties) do
    %{
      "type" => "object",
      "properties" => properties,
      "required" => Map.keys(properties) |> Enum.sort(),
      "additionalProperties" => false
    }
  end

  defp id_schema([]), do: text()
  defp id_schema(ids), do: %{"type" => "string", "enum" => ids}
  defp text, do: %{"type" => "string", "minLength" => 1}

  defp references do
    %{
      "type" => "array",
      "minItems" => 1,
      "items" =>
        object(%{
          "path" => text(),
          "locator" => text()
        })
    }
  end
end

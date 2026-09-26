defmodule Kogen.Build.FailureSignature do
  @moduledoc "Bounded descriptive fingerprints derived only from settled receipts."
  @head_limit 320

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def derive(cycle, context, catalog, previous \\ []) do
    receipts = cycle["receipts"] || []

    # A controller cycle can also fail outside a target receipt (catalog,
    # proof selector, target evidence or Candidate mutation).
    failed =
      Enum.find(receipts, &(not passed?(&1))) || cycle["failure"] || List.last(receipts) || %{}

    output = to_string(failed["output"] || failed["reason"] || "")

    head =
      output
      |> String.replace(~r/\e\[[0-9;]*m/, "")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> String.slice(0, @head_limit)

    target = failed["target"] || cycle["failed_target"] || "unknown"
    identity = first_identity(output, target)
    digest = sha256(Enum.join([target, identity, head], "\n"))

    paid_index =
      Enum.find_index(
        context["targets"] || [],
        &(get_in(catalog, [:targets, &1, "provider_backed"]) == true)
      )

    failed_index = Enum.find_index(receipts, &(&1["target"] == target)) || 0

    signature = %{
      "candidate_id" => cycle["candidate_id"],
      "cycle" => cycle["sequence"],
      "target" => target,
      "cost_class" => get_in(catalog, [:targets, target, "cost_class"]) || "unknown",
      "first_failure" => identity,
      "error_head" => head,
      "digest" => digest,
      "before_first_paid" => is_nil(paid_index) or failed_index < paid_index
    }

    Map.put(signature, "repeated", Enum.any?(previous, &(&1["digest"] == digest)))
  end

  defp passed?(%{"status" => status}) when is_binary(status), do: status in ["passed", "pass"]
  defp passed?(receipt), do: receipt["exit_code"] == 0

  defp first_identity(output, fallback) do
    case Regex.run(~r/(?:test\/[^:\s]+(?::\d+)?|(?:mix|python3?|make) [^\n]+)/, output) do
      [match | _] -> String.slice(match, 0, 160)
      _ -> fallback
    end
  end

  defp sha256(value), do: Base.encode16(:crypto.hash(:sha256, value), case: :lower)
end

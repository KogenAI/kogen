defmodule Kogen.Build.Review do
  @moduledoc """
  Enforces the Reviewer's verification-surface ledger dispositions.

  The Reviewer returns exactly one disposition per ledger item in the verdict's
  `ledger` field (`Kogen.Build.Contract.verdict/5` rejects a missing, extra
  or malformed one through the malformed-verdict path). A `weakening`
  disposition opens a blocking finding and turns the verdict into rework, so
  the change goes back to the same Developer as Review rework.
  """

  alias Kogen.Build.VerificationPlan

  @doc "The verdict with one blocking finding per `weakening` ledger disposition."
  def apply_ledger(response, nil, _contract), do: response

  def apply_ledger(response, ledger, contract) do
    items = Map.new(ledger["items"], &{&1["path"], &1})

    weakened =
      for %{"path" => path, "disposition" => "weakening"} <- Map.get(response, "ledger", []),
          do: items[path]

    if weakened == [] do
      response
    else
      findings = Enum.map(weakened, &finding(&1, contract))

      response
      |> Map.put("verdict", "rework")
      |> Map.update!("findings", &(&1 ++ findings))
    end
  end

  defp finding(item, contract) do
    %{
      "scenario_ids" => scenario_ids(item["path"], contract),
      "reason" =>
        "Verification-surface ledger item `#{item["path"]}` (#{item["status"]}#{if item["runner_class"], do: ", runner-class", else: ""}) was marked `weakening` by the Reviewer: restore the verification strength or justify the change against the approved contract.",
      "evidence" => [
        %{
          "path" => item["diff"]["path"],
          "locator" => "verification-surface ledger diff of #{item["path"]}"
        }
      ]
    }
  end

  defp scenario_ids(path, contract) do
    ids =
      for scenario <- contract.scenarios,
          proof = scenario["proof"] || %{},
          Enum.any?(
            List.wrap(proof["affected_paths"]) ++ List.wrap(proof["offline"]),
            &covers?(&1, path)
          ),
          do: scenario["id"]

    if ids == [], do: Enum.map(contract.scenarios, & &1["id"]), else: ids
  end

  defp covers?(pattern, path) do
    root = String.trim_trailing(pattern, "/")

    path == root or String.starts_with?(path, root <> "/") or
      VerificationPlan.path_matches?(path, pattern)
  end
end

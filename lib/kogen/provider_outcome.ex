defmodule Kogen.Codex.ProviderOutcome do
  @moduledoc "Normalizes provider execution without allowing cleanup to replace its initiating cause."

  @terminal ~w(succeeded login_failed runtime_missing incompatible routing_failed provider_failed timed_out cancelled malformed_evidence)a

  def settle(kind, details \\ %{}, cleanup \\ :ok)

  def settle(kind, details, cleanup) when kind in @terminal and is_map(details) do
    %{
      status: kind,
      success: kind == :succeeded and cleanup == :ok,
      cause: details,
      cleanup: normalize_cleanup(cleanup)
    }
  end

  def settle(:intermediate, details, cleanup) do
    settle(:malformed_evidence, Map.put(details, :reason, :non_final_evidence), cleanup)
  end

  def settle(kind, _details, cleanup) do
    settle(:malformed_evidence, %{reason: {:unknown_outcome, kind}}, cleanup)
  end

  defp normalize_cleanup(:ok), do: %{status: :passed}
  defp normalize_cleanup({:error, reason}), do: %{status: :failed, reason: reason}
  defp normalize_cleanup(other), do: %{status: :failed, reason: {:invalid_cleanup, other}}
end

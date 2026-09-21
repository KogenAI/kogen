defmodule Kogen.ProviderOutcomeTest do
  use ExUnit.Case, async: true

  alias Kogen.Codex.ProviderOutcome

  test "provider boundaries remain distinct and only final clean success authorizes completion" do
    failures =
      ~w(login_failed runtime_missing incompatible routing_failed provider_failed timed_out cancelled malformed_evidence)a

    for kind <- failures do
      outcome = ProviderOutcome.settle(kind, %{boundary: kind})
      assert outcome.status == kind
      refute outcome.success
      assert outcome.cause == %{boundary: kind}
    end

    assert ProviderOutcome.settle(:succeeded, %{final: true}).success
    refute ProviderOutcome.settle(:intermediate, %{schema_shaped: true}).success
  end

  test "cleanup failure is retained without erasing the provider cause" do
    outcome = ProviderOutcome.settle(:timed_out, %{timeout_ms: 25}, {:error, :descendant_alive})
    assert outcome.status == :timed_out
    assert outcome.cause == %{timeout_ms: 25}
    assert outcome.cleanup == %{status: :failed, reason: :descendant_alive}
  end
end

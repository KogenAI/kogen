defmodule Kogen.FailureSignatureTest do
  use ExUnit.Case, async: true

  alias Kogen.Build.FailureSignature

  test "the first failed receipt remains primary and repeated signatures are explicit" do
    cycle = %{
      "candidate_id" => "candidate-a",
      "sequence" => 2,
      "receipts" => [
        %{
          "target" => "check",
          "status" => "failed",
          "exit_code" => 3,
          "output" => "test/a_test.exs:9 initiating"
        },
        %{
          "target" => "cleanup",
          "status" => "failed",
          "exit_code" => 4,
          "output" => "later cleanup"
        }
      ]
    }

    context = %{"targets" => ["check", "live-native"]}

    catalog = %{
      targets: %{
        "check" => %{"cost_class" => "offline"},
        "live-native" => %{"provider_backed" => true}
      }
    }

    first = FailureSignature.derive(cycle, context, catalog)
    repeated = FailureSignature.derive(cycle, context, catalog, [first])

    assert first["target"] == "check"
    assert first["first_failure"] == "test/a_test.exs:9"
    assert first["before_first_paid"]
    refute first["repeated"]
    assert repeated["repeated"]
  end
end

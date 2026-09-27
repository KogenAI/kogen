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

defmodule Kogen.Harness.ProviderMarkerTest do
  use ExUnit.Case, async: true

  alias Kogen.Harness.ProviderMarker

  @fixtures_dir Path.expand("../support/provider_tails", __DIR__)

  defp fixture(name) do
    path = Path.join(@fixtures_dir, name)
    json = path |> File.read!() |> Jason.decode!()
    provenance = Map.fetch!(json, "provenance")

    # Every committed excerpt carries its Build id, source record path and
    # original receipt/verdict sha256 as provenance (mined-fixture-ownership).
    assert is_binary(provenance["build_id"]) and provenance["build_id"] != ""
    assert is_binary(provenance["source_record_path"]) and provenance["source_record_path"] != ""
    assert provenance["sha256"] =~ ~r/^[0-9a-f]{64}$/

    Map.fetch!(json, "output")
  end

  test "Claude 429 session-limit is a usage-limit marker, never retried, and ignores the misleading subtype" do
    output = fixture("be_n9crq_claude_session_limit.json")
    assert output =~ "\"subtype\":\"success\""
    assert output =~ "You've hit your session limit"

    assert %{"class" => "provider", "kind" => "usage_limit", "retry" => false, "marker" => marker} =
             ProviderMarker.classify(output)

    assert marker =~ "\"api_error_status\":429"
  end

  test "the synthetic 5xx excerpt (BE-N9cRQ with api_error_status changed to 529) is a retried server_error" do
    output = fixture("be_n9crq_synthetic_5xx.json")
    assert output =~ "\"api_error_status\":529"

    assert %{"class" => "provider", "kind" => "server_error", "retry" => true, "marker" => marker} =
             ProviderMarker.classify(output)

    assert marker =~ "\"api_error_status\":529"
  end

  test "Codex exec/stream-json capacity text is a retried overload marker" do
    output = fixture("hjeqtbsg_codex_capacity_stream.json")
    assert output =~ "at capacity"

    assert %{"class" => "provider", "kind" => "overload", "retry" => true, "marker" => marker} =
             ProviderMarker.classify(output)

    assert marker =~ "at capacity"
  end

  test "Codex rollout's structured codex_error_info is a retried overload marker" do
    output = fixture("hjeqtbsg_codex_capacity_rollout.json")
    assert output =~ "server_overloaded"

    assert %{"class" => "provider", "kind" => "overload", "retry" => true, "marker" => marker} =
             ProviderMarker.classify(output)

    assert marker =~ "server_overloaded"
  end

  test "a Kogen harness turn timeout (exit 124) is never a provider marker" do
    output = fixture("btwokrnx_c1_turn_timeout_negative_control.json")
    assert output =~ "provider_exit, 124"
    refute ProviderMarker.classify(output)
  end

  test "an ExUnit test timeout is never a provider marker" do
    output = fixture("haoggjsc_c2_exunit_timeout_negative_control.json")
    assert output =~ "timed out after 120000ms"
    refute ProviderMarker.classify(output)
  end

  test "there is no whole-output regex: a bare 5xx-shaped timestamp never classifies as a marker" do
    refute ProviderMarker.classify("started at 14:03:26, file-size 583 bytes\n")
    refute ProviderMarker.classify("not json at all")
    refute ProviderMarker.classify("")
  end

  test "401 login tails are environment markers and stay separate from provider markers" do
    claude = fixture("xfjcrm76_claude_oauth_revoked.json")
    codex = fixture("synthetic_codex_refresh_failed.json")

    assert %{"class" => "environment", "kind" => "login_rejected", "harness" => "claude"} =
             ProviderMarker.login_failure(claude)

    assert %{"class" => "environment", "kind" => "login_rejected", "harness" => "codex"} =
             ProviderMarker.login_failure(codex)

    refute ProviderMarker.classify(claude)
    refute ProviderMarker.classify(codex)

    refute ProviderMarker.login_failure(
             Jason.encode!(%{"is_error" => true, "api_error_status" => 403})
           )
  end

  test "login commands follow the binding scope" do
    for harness <- ["claude", "codex"] do
      assert Kogen.Harness.login_command(%{harness: harness}) == "mix kogen.#{harness}.login"

      assert Kogen.Harness.login_command(%{harness: harness, scope: %{name: :project}}) ==
               "mix kogen.#{harness}.login --project"
    end
  end

  test "a marker can be anywhere inside a nested harness stream, not just at the end" do
    output =
      Enum.join(
        [
          Jason.encode!(%{"is_error" => true, "api_error_status" => 429, "subtype" => "success"}),
          "make: leftover noise after the marker line",
          "more trailing output that is not JSON at all"
        ],
        "\n"
      )

    assert %{"kind" => "usage_limit"} = ProviderMarker.classify(output)
  end
end

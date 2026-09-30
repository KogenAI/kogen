Code.require_file("../support/scripted_build_fixture.ex", __DIR__)

defmodule Kogen.BuildRepairAuthorityTest do
  alias Kogen.Build.ReviewPacket

  @moduledoc """
  Exercises the full controller handoff for ordinary repairs outside the
  predicted path footprint and confirms that Review receives the distinct,
  Candidate-bound disclosure.
  """
  use Kogen.IsolatedCase, async: true

  alias Kogen.ScriptedBuildFixture, as: Fixture

  test "an unpredicted generated fixture stays in the same Developer attempt and reaches Review" do
    dir = Fixture.fixture!()
    extra_path = "generated-fixture.txt"

    assert :ok =
             Fixture.run(dir,
               edits: %{1 => "printf 'generated fixture evidence\\n' > #{extra_path}"}
             )

    assert File.dir?(Path.join(dir, ".kogen/intents/complete/#{Fixture.slug()}"))

    record = Fixture.record!(dir)
    assert [attempt] = record["attempts"]
    assert Map.has_key?(attempt, "review_packet")
    assert attempt["guard_violations"] in [nil, []]

    assert %{"items" => [item]} = attempt["repair_disclosures"]
    assert item["path"] == extra_path
    assert item["hunks"] =~ "+generated fixture evidence"
    assert is_binary(item["hunks_sha256"])
    assert item["hunks_byte_count"] == byte_size(item["hunks"])
    assert item["reason"] == "unknown"
    assert item["feature_relationship"] == "unknown"
    assert item["failure_evidence"] == "unknown"

    packet = review_packet!(dir, attempt)
    assert packet["attempt_token"] == attempt["attempt_token"]
    assert packet["candidate_id"] == attempt["candidate_id"]
    assert %{"items" => [review_item]} = packet["repair_disclosures"]
    assert review_item["path"] == extra_path
    assert review_item["hunks"] == item["hunks"]
    assert packet["repair_disclosures"]["developer_rationale"] != nil
  end

  test "a Reviewer can request rework on a disclosed extra repair" do
    dir = Fixture.fixture!()
    extra_path = "generated-fixture.txt"

    assert :ok =
             Fixture.run(dir,
               reviews: "rework,accept",
               edits: %{
                 1 => "printf 'first fixture version\\n' > #{extra_path}",
                 2 => "printf 'revised fixture version\\n' > #{extra_path}"
               }
             )

    record = Fixture.record!(dir)
    assert length(record["attempts"]) == 2

    for attempt <- record["attempts"] do
      assert %{"items" => [item]} = attempt["repair_disclosures"]
      assert item["path"] == extra_path
      packet = review_packet!(dir, attempt)
      assert packet["repair_disclosures"]["items"] |> hd() |> Map.fetch!("path") == extra_path
    end
  end

  defp review_packet!(root, attempt) do
    binding = attempt["review_packet"]
    bytes = File.read!(Path.join(root, binding["path"]))
    assert byte_size(bytes) <= ReviewPacket.limit()
    assert binding["sha256"] == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    Jason.decode!(bytes)
  end
end

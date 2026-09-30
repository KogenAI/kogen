Code.require_file("../support/generic_project_fixture.ex", __DIR__)

defmodule Kogen.GenericProjectBuildTest do
  @moduledoc """
  Scenario `generic-project-catalog`: a fixture project that is not Kogen
  and has none of its checks (no `check`, no `cold-offline`, no
  offline.py, no rehearsals.exs, no ExUnit, no live Shaping driver). Its
  catalog carries one offline target (`test`) and one provider-backed
  target (`e2e`), with arbitrary ranks, no `prepare` and no Kogen frames in
  any output. A fake-harness Build over this catalog, through the real
  `Kogen.Build.run/1` consumer, proves the controller looks for no target,
  file or output format that only Kogen's own repository has.
  """
  use Kogen.IsolatedCase, async: true

  alias Kogen.GenericProjectFixture, as: Fixture

  test "test fails twice (offline) then passes; e2e never starts while test fails, then fails once (paid) and passes; the Build settles and reaches Review" do
    dir = Fixture.fixture!()

    assert :ok = Fixture.run(dir)

    tracking = Fixture.record!(dir)
    [attempt] = tracking["attempts"]
    cycles = attempt["verification"]["cycles"]

    # Four cycles: test fails (offline) x2, test passes and e2e fails
    # (paid) x1, both pass.
    assert Enum.map(cycles, & &1["status"]) == ["failed", "failed", "failed", "passed"]
    assert Enum.map(Enum.take(cycles, 3), & &1["class"]) == ["offline", "offline", "paid"]

    for cycle <- Enum.take(cycles, 2) do
      assert Enum.map(cycle["receipts"], & &1["target"]) == ["test"],
             "e2e must never start while test is still failing"
    end

    third = Enum.at(cycles, 2)
    assert Enum.map(third["receipts"], & &1["target"]) == ["test", "e2e"]

    # Offline failures spend only `offline_failures`; the one paid failure
    # spends one `verification_retries`, tracked separately.
    assert Enum.map(cycles, & &1["offline_failures_after"]) == [1, 2, 2, 2]
    assert Enum.map(cycles, & &1["failures_after"]) == [0, 0, 1, 0]

    assert attempt["outcome"] == "settled"

    # Handoffs and signatures: the fallback (no `KOGEN_FAILURE_SIGNATURE`
    # frame anywhere in this project's output).
    # Only failed cycles receive signatures; the successful fourth cycle
    # must not acquire a Review-stop signature. The three failures come from
    # the normalized tail. The two identical `test` failures share a digest
    # (the second is `repeated`), and the `e2e` failure differs.
    signatures = attempt["failure_signatures"]
    assert length(signatures) == Enum.count(cycles, &(&1["status"] == "failed"))
    [first, second, third] = signatures
    assert Enum.map([first, second, third], & &1["source"]) == ["tail", "tail", "tail"]
    assert Enum.map([first, second, third], & &1["target"]) == ["test", "test", "e2e"]
    assert first["digest"] == second["digest"]
    assert second["repeated"]
    refute third["digest"] == first["digest"]
    refute third["repeated"]

    # The earlier provisional Review cited dummy.txt before a legitimate
    # Developer repair changed the Candidate. Its live citation guard is
    # superseded for the repaired tree, while its exact bytes remain in the
    # tracking record's append-only sidecar history.
    old_reference =
      Enum.find_value(attempt["reference_snapshot_history"], fn entry ->
        case entry["snapshots"]["dummy.txt"] do
          %{} = snapshot -> {entry, snapshot}
          _ -> nil
        end
      end)

    assert {old_revision, snapshot} = old_reference
    refute old_revision["candidate_id"] == attempt["candidate_id"]

    retained_bytes =
      File.read!(Path.expand(snapshot["sidecar"], dir))

    assert byte_size(retained_bytes) == snapshot["byte_count"]

    assert Base.encode16(:crypto.hash(:sha256, retained_bytes), case: :lower) ==
             snapshot["sha256"]

    refute retained_bytes == File.read!(Path.join(dir, "dummy.txt"))

    # Each failed receipt's retained log carries the plain shell failure
    # text, with no Kogen frame.
    for cycle <- Enum.take(cycles, 3) do
      failed = Enum.find(cycle["receipts"], &(&1["status"] == "failed"))
      refute failed["output"] =~ "KOGEN_"
      assert failed["output"] =~ "failed:"
    end

    # A Developer resume prompt lists the failed receipt and log with the
    # normalized tail, from the fallback source (no frame).
    resume_prompts =
      Path.wildcard(Path.join(Kogen.CandidateFixture.fake_state(dir), "verification-resume-*"))

    assert resume_prompts != []

    for path <- resume_prompts do
      prompt = File.read!(path)
      assert prompt =~ "Retained receipt:"
      assert prompt =~ "Retained log:"
      assert prompt =~ "Primary failure lines:"
    end
  end
end

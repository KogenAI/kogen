Code.require_file("../support/scripted_build_fixture.ex", __DIR__)

defmodule Kogen.ReviewPacketTest do
  @moduledoc """
  The bounded, Candidate-bound review packet: canonical JSON under 64 KiB with
  per-field UTF-8-safe caps, digest-bound stubs whose locators resolve into
  the record, fail-closed required ids, and controller integrity binding
  through the real Review route.
  """
  use Kogen.IsolatedCase, async: true

  alias Kogen.Build.ReviewPacket
  alias Kogen.ScriptedBuildFixture, as: Fixture

  @keys ~w(attempt_number attempt_token base_suite build_id candidate_id developer_notes handoff
           omitted open_findings receipts record risk_ids scenario_ids schema_version
           superseded_objection verification_ledger)

  describe "packet construction" do
    test "oversized notes, receipts, findings and handoff fit the bound with digest-bound stubs" do
      record = oversized_record()
      record_bytes = Jason.encode!(record)
      assert byte_size(record_bytes) > 1_048_576

      assert {:ok, bytes} = ReviewPacket.build(input(record, record_bytes))
      assert byte_size(bytes) <= 65_536
      packet = Jason.decode!(bytes)

      # Canonical JSON with exactly the approved top-level keys.
      assert Enum.sort(Map.keys(packet)) == @keys
      assert ReviewPacket.encode(packet) == bytes
      assert bytes =~ ~r/^\{"attempt_number":/

      assert packet["schema_version"] == 1
      assert packet["build_id"] == "build-x"
      assert packet["attempt_number"] == 1
      assert packet["attempt_token"] == "token-1"
      assert packet["candidate_id"] == "candidate-1"
      assert packet["scenario_ids"] == ["s-one", "s-two"]
      assert packet["risk_ids"] == ["r-one"]
      assert Enum.map(packet["open_findings"], & &1["id"]) == ["F1", "F2", "F3"]

      assert packet["record"] == %{
               "path" => ".kogen/runtime/scenario-tracking/build-x/record.json",
               "byte_count" => byte_size(record_bytes),
               "use" => packet["record"]["use"]
             }

      assert packet["record"]["use"] =~ "audit locator only"

      # Notes: a 16 KiB head, cut at a code point boundary.
      notes = packet["developer_notes"]
      source = get_in(record, ["attempts", Access.at(1), "developer_notes", "text"])
      assert_stub!(notes, record, source, "/attempts/1/developer_notes/text")
      assert byte_size(notes["text"]) <= 16_384
      assert byte_size(notes["text"]) > 16_380
      assert String.starts_with?(source, notes["text"])

      # Receipts: a 2 KiB tail of each output, bound to target and Candidate.
      assert [check, target] = packet["receipts"]
      assert check["target"] == "check"
      assert target["target"] == "live"

      for {receipt, locator} <- [
            {check, "/attempts/1/receipts/0"},
            {target, "/attempts/1/receipts/1"}
          ] do
        output = resolve!(record, locator <> "/output")
        assert receipt["status"] == "passed"
        assert receipt["candidate_id"] == "candidate-1"
        assert receipt["locator"] == locator
        assert receipt["output_byte_count"] == byte_size(output)
        assert receipt["output_sha256"] == sha256(output)
        assert_stub!(receipt["output"], record, output, locator <> "/output")
        assert byte_size(receipt["output"]["text"]) <= 2_048
        assert String.ends_with?(output, receipt["output"]["text"])
      end

      # Findings keep their ids; disposition history is kept or digest-bound.
      for finding <- packet["open_findings"] do
        [f] = Enum.filter(record["findings"], &(&1["id"] == finding["id"]))
        assert finding["status"] == "open" or finding["omitted"]

        if finding["disposition_history"] do
          assert length(finding["disposition_history"]) ==
                   length(f["disposition_history"])
        end
      end

      # The handoff fits its 24 KiB cap without byte-slicing JSON.
      assert byte_size(ReviewPacket.encode(packet["handoff"])) <= 24_576
      assert packet["handoff"]["format"] == "kogen-controller-handoff-report"

      # Every cut item is listed with its digest and locator, and every
      # digest matches the source the locator names.
      stubs = collect_stubs(packet)
      assert stubs != []

      for stub <- stubs do
        assert Enum.any?(
                 packet["omitted"],
                 &(&1["locator"] == stub["locator"] and &1["sha256"] == stub["sha256"])
               )
      end

      for item <- packet["omitted"] do
        value = resolve!(record, item["locator"])
        source = if is_binary(value), do: value, else: ReviewPacket.encode(value)
        assert item["sha256"] == sha256(source), item["locator"]
        assert item["byte_count"] == byte_size(source), item["locator"]
      end

      # Left-out sections: the prior attempt and the verification history.
      assert Enum.any?(packet["omitted"], &(&1["locator"] == "/attempts/0"))
      assert Enum.any?(packet["omitted"], &(&1["locator"] == "/attempts/1/verification"))
    end

    test "small inputs are carried whole, with nothing omitted but left-out sections" do
      record = small_record()
      bytes = Jason.encode!(record)
      assert {:ok, packet} = ReviewPacket.build(input(record, bytes))
      packet = Jason.decode!(packet)
      attempt = List.last(record["attempts"])
      assert packet["developer_notes"] == attempt["developer_notes"]["text"]
      assert packet["handoff"] == attempt["handoff"]
      assert hd(packet["receipts"])["output"] == hd(attempt["receipts"])["output"]
      assert Enum.all?(packet["omitted"], &(&1["kind"] == "left_out"))
    end

    test "a packet grows tighter rather than exceeding the bound" do
      record =
        oversized_record()
        |> update_in(["attempts", Access.at(1), "receipts"], fn [check, live] ->
          [check | for(index <- 1..40, do: %{live | "target" => "live-#{index}"})]
        end)

      assert {:ok, bytes} = ReviewPacket.build(input(record, Jason.encode!(record)))
      assert byte_size(bytes) <= 65_536
      packet = Jason.decode!(bytes)
      assert length(packet["receipts"]) == 41
      assert Enum.map(packet["open_findings"], & &1["id"]) == ["F1", "F2", "F3"]
      assert packet["scenario_ids"] == ["s-one", "s-two"]
    end

    test "required ids that alone exceed the bound are an integrity error, never dropped" do
      ids = for index <- 1..3_000, do: "scenario-#{index}-" <> String.duplicate("x", 20)

      record =
        small_record()
        |> Map.put("scenarios", Enum.map(ids, &%{"id" => &1}))

      assert {:error, reason} = ReviewPacket.build(input(record, Jason.encode!(record)))
      assert reason =~ "review packet integrity failure"
      assert reason =~ "65536"
    end

    test "notes that are not valid UTF-8 are bound by digest and never sliced" do
      notes = <<0xFF, 0xFE, "raw">>

      record =
        update_in(small_record(), ["attempts", Access.at(1), "developer_notes"], fn _ ->
          %{
            "sha256" => sha256(notes),
            "byte_count" => byte_size(notes),
            "content_base64" => Base.encode64(notes),
            "text" => nil
          }
        end)

      assert {:ok, bytes} = ReviewPacket.build(input(record, Jason.encode!(record)))
      notes_stub = Jason.decode!(bytes)["developer_notes"]
      assert notes_stub["truncated"]
      assert notes_stub["sha256"] == sha256(notes)
      assert notes_stub["locator"] == "/attempts/1/developer_notes/content_base64"
    end

    test "a reused receipt (reused_from) appears in the packet receipts" do
      record =
        update_in(small_record(), ["attempts", Access.at(1), "receipts"], fn [receipt] ->
          [
            receipt,
            Map.put(receipt, "reused_from", %{"cycle_sequence" => 1, "log_sha256" => "abc"})
          ]
        end)

      assert {:ok, bytes} = ReviewPacket.build(input(record, Jason.encode!(record)))
      packet = Jason.decode!(bytes)
      assert [_first, reused] = packet["receipts"]
      assert reused["reused_from"] == %{"cycle_sequence" => 1, "log_sha256" => "abc"}
    end
  end

  describe "the real Review route" do
    test "each attempt's packet is written once before launch and bound in state and record" do
      dir = Fixture.fixture!()
      notes = String.duplicate("Developer notes with ünïcödé détail. ", 1_100)
      assert byte_size(notes) > 32_768

      assert :ok =
               Fixture.run(dir,
                 notes: [notes, notes, notes, notes],
                 reviews: "rework,rework,rework,accept",
                 check_output: 70_000,
                 edits: %{1 => "printf 'changed\\n' > dummy.txt"}
               )

      record_path = Fixture.record_path!(dir)
      assert File.stat!(record_path).size > 1_048_576
      record = Fixture.record!(dir)
      assert length(record["attempts"]) == 4

      for {attempt, index} <- Enum.with_index(record["attempts"]) do
        n = index + 1
        binding = attempt["review_packet"]
        relative = Path.relative_to(record_path, dir)

        assert binding["path"] ==
                 Path.join(Path.dirname(relative), "review-packets/#{attempt["number"]}.json")

        bytes = File.read!(Path.join(dir, binding["path"]))
        assert byte_size(bytes) <= 65_536
        assert binding["sha256"] == sha256(bytes)
        assert binding["byte_count"] == byte_size(bytes)
        assert binding["attempt_token"] == attempt["attempt_token"]
        assert binding["candidate_id"] == attempt["candidate_id"]

        # The Reviewer read exactly the bytes written before its launch.
        assert File.read!(Path.join(dir, ".kogen/runtime/reviewer-packet-#{n}.json")) == bytes

        packet = Jason.decode!(bytes)
        assert packet["attempt_token"] == attempt["attempt_token"]
        assert packet["candidate_id"] == attempt["candidate_id"]
        assert packet["attempt_number"] == attempt["number"]
        assert packet["developer_notes"]["truncated"]
        assert hd(packet["receipts"])["output"]["truncated"]
        assert String.valid?(hd(packet["receipts"])["output"]["text"])

        # The Reviewer's context names the packet as its evidence source and
        # keeps the record path as an audit locator for existing consumers.
        context = Fixture.task_context!(Fixture.reviewer_prompt!(dir, n))
        assert context["evidence_source"] == "review_packet"
        assert context["review_packet"] == Map.take(binding, ["path", "sha256", "byte_count"])
        assert context["tracking_path"] == relative
        assert context["tracking_record"]["path"] == relative
        assert context["tracking_record"]["use"] =~ "audit locator only"
        assert is_integer(context["tracking_record"]["byte_count"])
      end

      last = List.last(record["attempts"])
      packet = Jason.decode!(File.read!(Path.join(dir, last["review_packet"]["path"])))
      assert Enum.map(packet["open_findings"], & &1["id"]) == ["F1", "F2", "F3"]

      assert Enum.map(packet["open_findings"], &length(&1["disposition_history"])) == [2, 1, 0]
      assert packet["open_findings"] |> hd() |> get_in(["origin", "reason"]) == "fixture rework"
    end

    test "a Reviewer that edits its packet stops the Build without publication" do
      dir = Fixture.fixture!()

      assert {:error, reason} = Fixture.run(dir, packet_mutation: 1)
      assert reason =~ "Reviewer failure: review packet mutated"
      refute File.dir?(Path.join(dir, ".kogen/intents/complete/#{Fixture.slug()}"))
      [attempt] = Fixture.record!(dir)["attempts"]
      refute Map.has_key?(attempt, "verdict")
    end

    test "a deleted earlier packet stops the next attempt before its Developer launch" do
      dir = Fixture.fixture!()

      assert {:error, reason} =
               Fixture.run(dir,
                 reviews: "rework",
                 edits: %{2 => "rm .kogen/runtime/scenario-tracking/*/review-packets/0.json"}
               )

      assert reason =~ "review packet missing"
      refute File.dir?(Path.join(dir, ".kogen/intents/complete/#{Fixture.slug()}"))
    end

    test "the Reviewer prompt starts from the packet and still requires Candidate inspection" do
      dir = Fixture.fixture!()
      assert :ok = Fixture.run(dir)
      prompt = String.replace(Fixture.reviewer_prompt!(dir, 1), ~r/\s+/, " ")

      assert prompt =~ "is your evidence source: read that packet first"
      assert prompt =~ "never dump or print the whole record"
      assert prompt =~ "The packet bounds the controller's evidence, never your inspection"
      assert prompt =~ "You must still read the Candidate files"
      assert prompt =~ "you may run read-only commands"
      assert prompt =~ "Start from the review packet"
    end

    test "reviewer.md ends with a mandatory completeness step over both id lists" do
      source = File.read!(Path.join(File.cwd!(), "priv/kogen/prompts/reviewer.md"))

      # The step is the prompt's last section, so it is the final instruction
      # a Reviewer reads before returning (Build qWusXkQn dropped a scenario id).
      [_before, step] = String.split(source, "## Mandatory completeness step\n")
      refute step =~ ~r/^#/m
      step = String.replace(step, ~r/\s+/, " ")

      assert step =~ "Before you return the verdict"
      assert step =~ "This step is mandatory"
      assert step =~ "every Approved scenario id, taken from the review packet's `scenario_ids`"
      assert step =~ "each one appears exactly once in `scenarios`"
      assert step =~ "every finding id that was open when Review began"
      assert step =~ "`open_findings`"
      assert step =~ "each one appears exactly once in `dispositions`"
      assert step =~ "fix the verdict before returning it"

      dir = Fixture.fixture!()
      assert :ok = Fixture.run(dir)
      prompt = String.replace(Fixture.reviewer_prompt!(dir, 1), ~r/\s+/, " ")
      assert prompt =~ "Mandatory completeness step"
    end
  end

  defp assert_stub!(stub, record, source, locator) do
    assert stub["truncated"] == true
    assert stub["locator"] == locator
    assert resolve!(record, locator) == source
    assert stub["sha256"] == sha256(source)
    assert stub["byte_count"] == byte_size(source)
    assert String.valid?(stub["text"])
  end

  defp collect_stubs(%{"truncated" => true} = stub), do: [stub]
  defp collect_stubs(%{"omitted" => true, "locator" => _} = stub), do: [stub]

  defp collect_stubs(map) when is_map(map),
    do: map |> Map.drop(["omitted"]) |> Map.values() |> Enum.flat_map(&collect_stubs/1)

  defp collect_stubs(list) when is_list(list), do: Enum.flat_map(list, &collect_stubs/1)
  defp collect_stubs(_value), do: []

  defp resolve!(value, "/" <> pointer) do
    pointer
    |> String.split("/")
    |> Enum.map(&(&1 |> String.replace("~1", "/") |> String.replace("~0", "~")))
    |> Enum.reduce(value, fn
      token, list when is_list(list) -> Enum.at(list, String.to_integer(token))
      token, map when is_map(map) -> Map.fetch!(map, token)
    end)
  end

  defp input(record, record_bytes) do
    %{
      record: record,
      record_path: ".kogen/runtime/scenario-tracking/build-x/record.json",
      record_bytes: record_bytes,
      candidate_id: "candidate-1",
      open_findings:
        record["findings"] |> Enum.filter(&(&1["status"] == "open")) |> Enum.map(& &1["id"])
    }
  end

  defp small_record do
    receipt = %{
      "target" => "check",
      "status" => "passed",
      "exit_code" => 0,
      "candidate_id" => "candidate-1",
      "attempt_token" => "token-1",
      "session_id" => "dev",
      "finished_at" => "2026-09-25T00:00:00Z",
      "output" => "ok\n"
    }

    %{
      "scenarios" => [%{"id" => "s-one"}, %{"id" => "s-two"}],
      "risks" => [%{"id" => "r-one"}],
      "findings" => [],
      "attempts" => [
        %{"number" => 0, "attempt_token" => "token-0", "status" => "failed"},
        %{
          "number" => 1,
          "attempt_token" => "token-1",
          "candidate_id" => "candidate-1",
          "developer_notes" => %{"text" => "All done."},
          "receipts" => [receipt],
          "verification" => %{"cycles" => [%{"sequence" => 1, "receipts" => [receipt]}]},
          "handoff" => %{"format" => "kogen-controller-handoff-report", "scenarios" => []}
        }
      ]
    }
  end

  defp oversized_record do
    output = String.duplicate("é", 40_000) <> "tail end of the output\n"
    notes = String.duplicate("notes ünïcödé ", 3_000)

    receipt = %{
      hd(small_record()["attempts"] |> List.last() |> Map.fetch!("receipts"))
      | "output" => output
    }

    history = fn count ->
      for index <- 1..count//1 do
        %{
          "reviewer_session" => "review-#{index}",
          "status" => "open",
          "reason" => String.duplicate("still open because ", 400),
          "evidence" => [%{"path" => "lib/x.ex", "locator" => "line #{index}"}]
        }
      end
    end

    findings =
      for {id, count} <- [{"F1", 2}, {"F2", 1}, {"F3", 0}] do
        %{
          "id" => id,
          "scenario_ids" => ["s-one"],
          "status" => "open",
          "origin" => %{"reason" => String.duplicate("finding reason ", 500)},
          "disposition_history" => history.(count)
        }
      end

    handoff = %{
      "format" => "kogen-controller-handoff-report",
      "scenarios" =>
        for id <- ["s-one", "s-two"] do
          %{"id" => id, "note" => String.duplicate("affected path note ", 1_000)}
        end
    }

    small_record()
    |> Map.put("findings", findings ++ [%{"id" => "F0", "status" => "closed"}])
    |> update_in(["attempts", Access.at(0)], &Map.put(&1, "bulk", String.duplicate("b", 600_000)))
    |> update_in(["attempts", Access.at(1)], fn attempt ->
      Map.merge(attempt, %{
        "developer_notes" => %{"text" => notes},
        "receipts" => [receipt, %{receipt | "target" => "live"}],
        "verification" => %{
          "cycles" =>
            for(sequence <- 1..6, do: %{"sequence" => sequence, "receipts" => [receipt]})
        },
        "handoff" => handoff
      })
    end)
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end

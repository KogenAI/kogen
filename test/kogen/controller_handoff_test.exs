Code.require_file("../support/fake_jev.ex", __DIR__)

defmodule Kogen.ControllerHandoffTest do
  @moduledoc """
  Controller-built Developer handoff reports, free-prose Developer notes read
  once by an offline fake Jev, the calibrated cannot-comply stop, Jev
  unavailability, and missing declared proof selectors, all driven through the
  real `Kogen.Build.run/1` consumer with a scripted Codex-protocol provider.
  """
  use Kogen.IsolatedCase, async: true

  alias Kogen.Build.Report
  alias Kogen.FakeJev

  @slug "controller-handoff"
  @root Path.expand("../..", __DIR__)
  @selector "test/kogen/handoff_selector_test.exs"
  @late_selector "test/kogen/late_selector_test.exs"
  @prefix "Developer cannot comply as approved; return to Shaping:"

  @old_shape_notes ~s({"attempt_token":"stale","scenarios":[{"id":"s-change","status":"ready","claim":"done","implementation":[{"path":"lib","locator":"x"}],"evidence":[]}],"risks":[{"id":"r-shared","scenario_ids":["s-preserve"],"response":"moved","evidence":[]}],"findings":[]})

  @variants [
    {"prose", "Both scenarios are done. Nothing is unfinished and I have no objection."},
    {"prose then JSON", ~s(Summary follows.\n{"attempt_token":"x","scenarios":[]})},
    {"malformed JSON", ~s({"attempt_token": "x", "scenarios": [}, oops})},
    {"truncated JSON", ~s({"attempt_token":"x","scenarios":[{"id":"s-cha)},
    {"old handoff shape", @old_shape_notes},
    {"empty", ""}
  ]

  test "every Developer message variant yields the same controller report and reaches Review" do
    reports =
      for {label, notes} <- @variants do
        dir = fixture!()
        result = run(dir, notes: [notes], edits: %{1 => "printf 'changed\\n' > dummy.txt"})
        assert result == :ok, "#{label}: #{inspect(result)}"

        [attempt] = record!(dir)["attempts"]
        assert Base.decode64!(attempt["developer_notes"]["content_base64"]) == notes, label
        assert attempt["developer_notes"]["text"] == notes
        assert attempt["developer_notes"]["label"] =~ "unverified"
        assert attempt["developer_invocation"]["message"] == notes
        refute Map.has_key?(attempt["developer_invocation"], "schema")
        assert attempt["outcome"] == "settled"
        assert attempt["jev"]["outcome"] == "answered"
        assert File.read!(Path.join(dir, ".kogen/runtime/reviews")) == "1"
        assert File.dir?(Path.join(dir, ".kogen/intents/complete/#{@slug}"))

        report = attempt["handoff"]
        assert report["attempt_token"] == attempt["attempt_token"]
        assert report["candidate_id"] == attempt["candidate_id"]
        check = Enum.find(report["receipts"], &(&1["target"] == "check"))
        assert check["status"] == "passed"
        assert check["attempt_token"] == attempt["attempt_token"]
        assert check["candidate_id"] == attempt["candidate_id"]

        assert Map.keys(attempt["developer_reference_snapshots"]) |> Enum.sort() ==
                 ["dummy.txt", @selector]

        normalize(report)
      end

    [first | rest] = reports
    assert Enum.all?(rest, &(&1 == first))

    assert Enum.map(first["scenarios"], & &1["id"]) == ["s-change", "s-preserve"]
    [change, preserve] = first["scenarios"]

    assert change["changed_affected_paths"] == [
             %{
               "path" => "dummy.txt",
               "change" => "modified",
               "locator" => "changed in Candidate relative to HEAD (modified)"
             }
           ]

    assert change["affected_paths_note"] == nil
    assert change["paid_target"] == "none"

    assert change["offline_selectors"] == [
             %{
               "selector" => @selector,
               "path" => @selector,
               "locator" => "declared offline selector"
             }
           ]

    assert preserve["changed_affected_paths"] == []
    assert preserve["affected_paths_note"] =~ "not a failure"

    assert first["risks"] == [
             %{"id" => "r-shared", "scenario_ids" => ["s-change", "s-preserve"]},
             %{"id" => "r-preserve", "scenario_ids" => ["s-preserve"]}
           ]

    assert first["findings"] == []
    assert first["built_by"] == "controller"
  end

  test "changing the Candidate's affected paths changes the report, and a deleted path is never cited" do
    dir = fixture!()

    assert :ok =
             run(dir,
               edits: %{
                 1 =>
                   "printf 'changed\\n' > dummy.txt; printf 'kept\\n' > keep.txt; rm retired.txt"
               }
             )

    [attempt] = record!(dir)["attempts"]
    [_change, preserve] = attempt["handoff"]["scenarios"]

    assert preserve["changed_affected_paths"] == [
             %{
               "path" => "keep.txt",
               "change" => "modified",
               "locator" => "changed in Candidate relative to HEAD (modified)"
             },
             %{"path" => "retired.txt", "change" => "deleted"}
           ]

    assert preserve["affected_paths_note"] == nil
    snapshots = attempt["developer_reference_snapshots"]
    assert Map.has_key?(snapshots, "keep.txt")
    refute Map.has_key?(snapshots, "retired.txt")
    # Unrelated changes are never listed under a scenario's affected paths.
    refute Enum.any?(preserve["changed_affected_paths"], &(&1["path"] == "dummy.txt"))
  end

  test "the report builder is total and identical for any message bytes and any Jev outcome" do
    :rand.seed(:exsss, {7, 11, 13})
    contract = %{scenarios: scenarios_data(), risks: risks_data()}

    inputs = %{
      contract: contract,
      attempt_token: "token",
      candidate_id: "candidate",
      open_findings: [%{"id" => "F1", "scenario_ids" => ["s-change"], "origin" => %{}}],
      changes: [{"dummy.txt", "modified"}, {"retired.txt", "deleted"}, {"other.txt", "added"}],
      receipts: [
        %{"target" => "check", "status" => "passed", "output" => "ok"}
      ],
      existing?: &(&1 in ["dummy.txt", @selector])
    }

    items = [%{"kind" => "scenario", "id" => "s-change"}]

    messages =
      [
        "",
        <<0xFF, 0xFE, 0x00>>,
        String.duplicate("x", 2_000_000),
        @old_shape_notes,
        "Developer cannot comply as approved"
      ] ++ for(_ <- 1..40, do: :crypto.strong_rand_bytes(:rand.uniform(512)))

    outcomes = [
      nil,
      %{"outcome" => "unavailable", "reason" => "timeout", "items" => items},
      %{
        "outcome" => "answered",
        "items" => items,
        "answers" => %{
          "status:s-change" => %{"choice" => "unfinished", "confidence" => 0.99},
          "objection:scenario:s-change" => %{"choice" => "objection", "confidence" => 0.99}
        }
      }
    ]

    expected = Report.build(inputs)

    for message <- messages, jev <- outcomes do
      assert Report.build(Map.merge(inputs, %{notes: message, jev: jev})) == expected
    end

    [finding] = expected["findings"]
    assert finding["id"] == "F1"
  end

  test "Build has no remaining code path that produces a Developer handoff invalid failure" do
    source = File.read!(Path.join(@root, "lib/kogen/build.ex"))
    refute source =~ "Developer handoff structure invalid"
    refute source =~ "Developer handoff semantic invalid"
    refute source =~ ~r/Developer handoff [^"]*invalid/
    refute source =~ "Contract.handoff("
    refute source =~ "DeveloperHandoff"
    refute source =~ "structured_output_"
    refute source =~ "handoff_valid?"
  end

  test "Build sends one pinned Jev request per settled attempt with the notes, IDs and calibrated wording" do
    dir = fixture!()
    notes = ["First attempt notes: s-change is done.", "Rework done for F1."]
    console = Path.join(dir, ".kogen/runtime/console.txt")

    assert :ok =
             run(dir,
               notes: notes,
               reviews: "rework,accept",
               edits: %{1 => "printf 'changed\\n' > dummy.txt"}
             )

    record = record!(dir)
    [first, second] = record["attempts"]
    requests = FakeJev.requests(jev_log(dir))
    assert length(requests) == 2

    for {attempt, request, text, items} <- [
          {first, Enum.at(requests, 0), Enum.at(notes, 0), base_items()},
          {second, Enum.at(requests, 1), Enum.at(notes, 1),
           base_items() ++ [%{"kind" => "finding", "id" => "F1"}]}
        ] do
      assert request["url"] == "https://api.typesafe.ai/v1/systemone"
      assert request["timeout_ms"] == 60_000
      assert request["header_names"] == ["authorization", "content-type"]
      assert request["authorization_matches_keychain"]
      assert request["body"] == Kogen.Jev.request_body(text, items)

      body = Jason.decode!(request["body"])
      assert body["model"] == "jev-1.13.0"
      assert body["state"] == %{"developer_notes" => text, "items" => items}

      assert body["questions"]["status:s-change"]["criteria"] |> Map.keys() |> Enum.sort() ==
               Enum.sort(
                 ~w(unfinished done pending_external resolved_or_historical objection_only unclear)
               )

      assert body["questions"]["objection:risk:r-shared"]["criteria"] |> Map.keys() |> Enum.sort() ==
               ~w(no_objection objection unclear)

      assert body["questions"]["objection:scenario:s-change"]["instructions"]["rules"] == [
               "Judge only what the notes state about this item.",
               "Unfinished work alone is not an objection."
             ]

      jev = attempt["jev"]
      assert jev["request"]["body"] == request["body"]
      assert jev["request"]["sha256"] == sha256(request["body"])
      assert [%{"status" => 200, "latency_ms" => latency}] = jev["exchanges"]
      assert is_integer(latency)
      assert jev["usage"]["input_tokens"] > 0
      assert jev["attempt_token"] == attempt["attempt_token"]
      assert jev["candidate_id"] == attempt["candidate_id"]
    end

    # Nothing Jev-related reaches the Developer's context.
    for call <- [1, 2] do
      prompt = File.read!(Path.join(dir, ".kogen/runtime/developer-prompt-#{call}"))
      refute prompt =~ "systemone"
      refute prompt =~ "objection:scenario"
      refute prompt =~ first["jev"]["request"]["sha256"]
    end

    File.write!(console, "")
    assert_no_key!(dir)
  end

  test "the fresh Reviewer is told the report is controller-built and sees labelled advisory Jev notes" do
    dir = fixture!()

    assert :ok =
             run(dir,
               notes: ["s-change still lacks its edge case; the rest is done."],
               jev_answers: %{"status:s-change" => ["unfinished", 0.93]}
             )

    prompt = File.read!(Path.join(dir, ".kogen/runtime/reviewer-prompt-1"))
    assert prompt =~ "is controller-built and contains no Developer self-assessment"

    assert prompt =~
             "you are responsible for finding unfinished or plausible-looking-only scenarios"

    assert prompt =~ "including prose responses to open findings, are unverified claims"
    assert prompt =~ "Jev only read the Developer's words and never judged the code"

    assert prompt =~
             "`changed_affected_paths` lists files that changed relative to HEAD, not where each behaviour lives"

    assert prompt =~
             "- scenario `s-change`: the Developer says s-change is unfinished (confidence 0.93)"

    assert prompt =~
             "- scenario `s-preserve`: the Developer says its work on s-preserve is done (confidence 0.97)"

    assert prompt =~ "- risk `r-shared`: no objection stated (confidence 0.98)"

    context = task_context!(prompt)
    assert context["handoff_report"] =~ "controller-built"
    assert context["developer_notes"] =~ "unverified claims"

    # The bounded review packet is the evidence source; the record stays an
    # audit locator under its existing key.
    [attempt] = record!(dir)["attempts"]
    assert context["evidence_source"] == "review_packet"

    assert context["review_packet"] ==
             Map.take(attempt["review_packet"], ["path", "sha256", "byte_count"])

    assert context["tracking_path"] == Path.relative_to(List.first(records(dir)), dir)
    assert context["tracking_record"]["use"] =~ "audit locator only"
    packet_bytes = File.read!(Path.join(dir, context["review_packet"]["path"]))
    assert sha256(packet_bytes) == context["review_packet"]["sha256"]
    packet = Jason.decode!(packet_bytes)
    assert packet["handoff"] == attempt["handoff"]
    assert packet["developer_notes"] == "s-change still lacks its edge case; the rest is done."
    assert prompt =~ "Review packet: `#{context["review_packet"]["path"]}`"
    assert context["jev_reading"]["advisory"] =~ "never findings or verification"

    assert %{"kind" => "scenario", "id" => "s-change", "notes" => notes} =
             hd(context["jev_reading"]["items"])

    assert hd(notes) == "the Developer says s-change is unfinished (confidence 0.93)"

    # A confident "unfinished" reading never routes rework by itself.
    record = record!(dir)
    assert [%{"verdict" => %{"verdict" => "accept"}}] = record["attempts"]
    refute File.exists?(Path.join(dir, ".kogen/runtime/developer-prompt-2"))
  end

  for {label, kind, id, confidence} <- [
        {"a scenario objection at 0.95", "scenario", "s-change", 0.95},
        {"a risk objection at 0.95", "risk", "r-preserve", 0.95},
        {"an objection exactly at 0.85", "scenario", "s-preserve", 0.85}
      ] do
    test "#{label} stops the Build without Review, resumption or publication" do
      dir = fixture!()
      notes = "The contract for this item cannot be met: it needs a change outside guarded paths."

      assert {:error, reason} =
               run(dir,
                 notes: [notes],
                 jev_answers: %{
                   "objection:#{unquote(kind)}:#{unquote(id)}" => [
                     "objection",
                     unquote(confidence)
                   ]
                 },
                 edits: %{1 => "printf 'changed\\n' > dummy.txt"}
               )

      assert String.starts_with?(reason, @prefix)
      confidence = unquote(confidence)

      assert reason =~
               "#{unquote(kind)} `#{unquote(id)}` (Jev confidence #{Kogen.Jev.format(confidence)})"

      assert reason =~ "Developer's notes: \"#{notes}\""
      refute File.exists?(Path.join(dir, ".kogen/runtime/reviews"))
      assert File.read!(Path.join(dir, ".kogen/runtime/developer-calls")) == "1"
      refute File.dir?(Path.join(dir, ".kogen/intents/complete/#{@slug}"))
      # The Candidate is kept for inspection like any stopped Build.
      assert File.read!(Path.join(dir, "dummy.txt")) == "changed\n"

      [attempt] = record!(dir)["attempts"]
      assert attempt["status"] == "failed"
      assert attempt["outcome"] == "cannot_comply"
      assert attempt["failure"] =~ @prefix

      assert [%{"kind" => unquote(kind), "id" => unquote(id)}] =
               attempt["cannot_comply"]["items"]

      assert attempt["cannot_comply"]["notes_quote"] == notes
      assert attempt["cannot_comply"]["threshold"] == 0.85
    end
  end

  test "an objection below 0.85 never stops the Build and reaches Review as a possible objection" do
    dir = fixture!()

    assert :ok =
             run(dir, jev_answers: %{"objection:scenario:s-change" => ["objection", 0.84]})

    prompt = File.read!(Path.join(dir, ".kogen/runtime/reviewer-prompt-1"))
    assert prompt =~ "possible objection (confidence 0.84)"
    [attempt] = record!(dir)["attempts"]
    assert attempt["outcome"] == "settled"
  end

  test "an open finding the Developer says it cannot address stops the Build as cannot-comply" do
    dir = fixture!()

    assert {:error, reason} =
             run(dir,
               notes: ["All done.", "F1 cannot be addressed as approved; it needs Shaping."],
               reviews: "rework",
               jev_answers: %{"objection:finding:F1" => ["objection", 0.95]}
             )

    assert String.starts_with?(reason, @prefix)
    assert reason =~ "finding `F1` (Jev confidence 0.95)"
    assert File.read!(Path.join(dir, ".kogen/runtime/reviews")) == "1"
    assert File.read!(Path.join(dir, ".kogen/runtime/developer-calls")) == "2"
    [_reworked, stopped] = record!(dir)["attempts"]
    assert stopped["outcome"] == "cannot_comply"
  end

  test "long notes are visibly truncated in the stop and name the record holding them" do
    dir = fixture!()
    notes = "I object: the contract is contradictory. " <> String.duplicate("detail ", 1_000)

    assert {:error, reason} =
             run(dir,
               notes: [notes],
               jev_answers: %{"objection:scenario:s-change" => ["objection", 0.99]}
             )

    [record_path] = records(dir)
    relative = Path.relative_to(record_path, dir)

    assert reason =~
             "[notes truncated at 2000 of #{String.length(notes)} characters; full notes in #{relative} attempt 0 developer_notes]"

    refute reason =~ notes
    [attempt] = record!(dir)["attempts"]
    assert attempt["cannot_comply"]["notes_truncated"]
    assert attempt["developer_notes"]["text"] == notes
  end

  # Controller verification exhaustion stops the Build before Jev and Review,
  # ahead of every other routing decision: a confident objection in the
  # Developer's notes is never even read, because Jev is never asked.
  test "an objection still leads the error when verification retries were exhausted" do
    dir = fixture!()

    assert {:error, reason} =
             run(dir,
               notes: ["I cannot meet s-change as approved."],
               edits: %{1 => "touch .kogen/runtime/fail-check"},
               jev_answers: %{"objection:scenario:s-change" => ["objection", 0.95]}
             )

    refute String.starts_with?(reason, @prefix)
    assert reason =~ ~r/^verification retries exhausted/
    assert Enum.empty?(FakeJev.requests(jev_log(dir)))
    [attempt] = record!(dir)["attempts"]
    refute Map.has_key?(attempt, "jev")
    refute File.exists?(Path.join(dir, ".kogen/runtime/reviews"))
  end

  test "exhausted verification without an objection still asks Jev and keeps the exhaustion reason" do
    dir = fixture!()

    assert {:error, reason} = run(dir, edits: %{1 => "touch .kogen/runtime/fail-check"})
    assert reason =~ ~r/^verification retries exhausted/
    [attempt] = record!(dir)["attempts"]
    refute Map.has_key?(attempt, "jev")
    assert Enum.empty?(FakeJev.requests(jev_log(dir)))
    refute File.exists?(Path.join(dir, ".kogen/runtime/reviews"))
  end

  @unavailable [
    {"two timeouts", [{:timeout}, {:timeout}], 2, "timeout after 60000 ms"},
    {"HTTP 400 max_tokens_exceeded", [{400, FakeJev.max_tokens_body()}], 1,
     "HTTP 400: " <> FakeJev.max_tokens_body()},
    {"HTTP 401", [{401, ~s({"detail":"invalid key"})}], 1, "HTTP 401"},
    {"HTTP 422", [{422, ~s({"detail":"bad request"})}], 1, "HTTP 422"},
    {"HTTP 429 after the retry", [{429, "slow down"}, {429, "slow down"}], 2, "HTTP 429"},
    {"HTTP 529 after the retry", [{529, "overloaded"}, {529, "overloaded"}], 2, "HTTP 529"},
    {"HTTP 500", [{500, "boom"}], 1, "HTTP 500"},
    {"a transport failure", [{:error, "connection refused"}], 1, "transport failure"},
    {"a body that is not JSON", [{200, "<html>oops</html>"}], 1, "not a JSON object"},
    {"a response for another model", [{200, :other_model}], 1, "jev-latest"},
    {"a partially valid response", [{200, :partial}], 1, "is missing"},
    {"a duplicated answer", [{200, :duplicated}], 1, "repeat status:s-change"},
    {"an answer with an unsent option", [{200, :invalid_option}], 1, "was not sent"}
  ]

  for {label, results, exchanges, reason} <- @unavailable do
    test "Jev unavailable (#{label}) reaches Review with the reason and never stops the Build" do
      dir = fixture!()
      responses = Path.join(dir, ".kogen/runtime/jev-responses")
      FakeJev.record_responses!(responses, materialize(unquote(Macro.escape(results))))

      assert :ok = run(dir, jev_responses: responses)
      assert_unavailable!(dir, unquote(exchanges), unquote(reason))
    end
  end

  test "a retried 529 that then answers is a normal reading" do
    dir = fixture!()
    responses = Path.join(dir, ".kogen/runtime/jev-responses")

    FakeJev.record_responses!(responses, [
      {529, "overloaded"},
      {200, FakeJev.answer_body(base_items())}
    ])

    assert :ok = run(dir, jev_responses: responses)
    [attempt] = record!(dir)["attempts"]
    assert attempt["jev"]["outcome"] == "answered"
    assert Enum.map(attempt["jev"]["exchanges"], & &1["status"]) == [529, 200]
  end

  test "a Keychain item that disappears after preconditions makes Jev unavailable, not a stop" do
    dir = fixture!()
    assert :ok = run(dir, security_item: "unreadable")
    assert_unavailable!(dir, 0, "Keychain item `dev.kogen.jev` could not be read at call time")
    assert FakeJev.requests(jev_log(dir)) == []
  end

  test "a missing declared proof selector is unfinished work that spends one outer resumption" do
    dir = fixture!(late_selector: true)

    assert :ok =
             run(dir,
               edits: %{
                 1 => "printf 'changed\\n' > dummy.txt",
                 2 => "printf '# late\\n' > #{@late_selector}"
               }
             )

    [unfinished, finished] = record!(dir)["attempts"]
    assert unfinished["outcome"] == "unfinished_work"
    assert unfinished["status"] == "failed"

    assert unfinished["failure"] ==
             "Unfinished work: missing declared proof selector #{@late_selector}"

    refute Map.has_key?(unfinished, "verdict")
    refute Map.has_key?(unfinished, "handoff")
    assert finished["verdict"]["verdict"] == "accept"
    assert File.read!(Path.join(dir, ".kogen/runtime/reviews")) == "1"
    # The next attempt settled a fresh Stop verification of its own.
    assert finished["verification"]["cycles"] != []
    assert finished["attempt_token"] != unfinished["attempt_token"]

    resume = File.read!(Path.join(dir, ".kogen/runtime/developer-prompt-2"))
    assert resume =~ "category: unfinished_work"

    [summary] =
      Path.wildcard(Path.join(dir, ".kogen/intents/complete/#{@slug}/build-summary*.json"))

    kinds =
      summary
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("attempts")
      |> Enum.map(& &1["failure_kind"])

    assert kinds == ["unfinished_work", nil]
  end

  test "a declared proof selector missing on every attempt stops after the outer resumptions" do
    dir = fixture!(late_selector: true)

    assert {:error, reason} = run(dir)

    assert reason =~
             "stopped after 2 outer resumptions without an accepting Review: Unfinished work: missing declared proof selector #{@late_selector}"

    assert File.read!(Path.join(dir, ".kogen/runtime/developer-calls")) == "3"
    refute File.exists?(Path.join(dir, ".kogen/runtime/reviews"))
  end

  test "a declared proof selector that exists is not unfinished work" do
    dir = fixture!(late_selector: true)
    assert :ok = run(dir, edits: %{1 => "printf '# late\\n' > #{@late_selector}"})
    assert [%{"outcome" => "settled"}] = record!(dir)["attempts"]
  end

  test "a cannot-comply reading takes precedence over a missing declared proof selector" do
    dir = fixture!(late_selector: true)

    assert {:error, reason} =
             run(dir, jev_answers: %{"objection:scenario:s-late" => ["objection", 0.9]})

    assert String.starts_with?(reason, @prefix)
    refute reason =~ "Unfinished work"
    assert File.read!(Path.join(dir, ".kogen/runtime/developer-calls")) == "1"
  end

  defp assert_unavailable!(dir, exchanges, reason) do
    [attempt] = record!(dir)["attempts"]
    jev = attempt["jev"]
    assert jev["outcome"] == "unavailable"
    assert jev["reason"] =~ reason
    assert jev["answers"] == nil
    assert length(jev["exchanges"]) == exchanges
    assert attempt["outcome"] == "settled"
    assert File.read!(Path.join(dir, ".kogen/runtime/reviews")) == "1"
    assert File.dir?(Path.join(dir, ".kogen/intents/complete/#{@slug}"))

    prompt = File.read!(Path.join(dir, ".kogen/runtime/reviewer-prompt-1"))

    for item <- base_items() do
      assert prompt =~
               "- #{item["kind"]} `#{item["id"]}`: Jev unavailable: #{jev["reason"]}; no Developer-notes reading was available"
    end

    assert_no_key!(dir)
  end

  defp materialize(results) do
    Enum.map(results, fn
      {200, :other_model} ->
        {200, FakeJev.answer_body(base_items(), %{}, "jev-latest")}

      {200, :partial} ->
        body = FakeJev.answer_body(base_items()) |> Jason.decode!()
        {200, Jason.encode!(update_in(body["answers"], &Map.delete(&1, "status:s-preserve")))}

      {200, :duplicated} ->
        answer = ~s({"type":"choice","choice":"done","confidence":0.9})
        body = FakeJev.answer_body(base_items())
        [head, tail] = String.split(body, ~s("answers":{), parts: 2)
        {200, head <> ~s("answers":{"status:s-change":) <> answer <> "," <> tail}

      {200, :invalid_option} ->
        {200, FakeJev.answer_body(base_items(), %{"status:s-change" => {"maybe", 0.9}})}

      other ->
        other
    end)
  end

  defp assert_no_key!(dir) do
    key = FakeJev.sentinel_key()

    for path <- Path.wildcard(Path.join(dir, ".kogen/**/*"), match_dot: true),
        File.regular?(path),
        not String.contains?(path, "/fake-jev/") do
      refute File.read!(path) =~ key, "Jev key leaked into #{path}"
    end
  end

  defp base_items do
    [
      %{"kind" => "scenario", "id" => "s-change"},
      %{"kind" => "scenario", "id" => "s-preserve"},
      %{"kind" => "risk", "id" => "r-shared"},
      %{"kind" => "risk", "id" => "r-preserve"}
    ]
  end

  # Fields that legitimately differ between otherwise identical Builds.
  defp normalize(report) do
    report
    |> Map.drop(["attempt_token", "candidate_id", "receipts", "reused_receipts"])
    |> Map.update!("scenarios", fn scenarios ->
      Enum.map(scenarios, &Map.delete(&1, "receipts"))
    end)
  end

  defp run(dir, opts \\ []) do
    notes_dir = Path.join(dir, ".kogen/runtime/handoff-notes")
    File.mkdir_p!(notes_dir)

    opts
    |> Keyword.get(:notes, [])
    |> Enum.with_index(1)
    |> Enum.each(fn {notes, call} ->
      File.write!(Path.join(notes_dir, "notes-#{call}"), notes)
    end)

    env =
      [
        {"KOGEN_HARNESS", Path.join(dir, "provider.py")},
        {"HANDOFF_NOTES_DIR", notes_dir},
        {"HANDOFF_REVIEWS", Keyword.get(opts, :reviews, "accept")},
        {"HANDOFF_RESPONSE_HELPER", Path.join(@root, "test/support/scenario_response.py")},
        {"FAKE_JEV_LOG_DIR", jev_log(dir)},
        {"FAKE_JEV_ANSWERS", Jason.encode!(Keyword.get(opts, :jev_answers, %{}))},
        {"FAKE_JEV_RESPONSES", Keyword.get(opts, :jev_responses)},
        {"FAKE_SECURITY_ITEM", Keyword.get(opts, :security_item, "present")},
        {"KOGEN_JEV_TRANSPORT", FakeJev.transport_path()},
        {"KOGEN_JEV_SECURITY", FakeJev.security_path()}
      ] ++
        Enum.map(Keyword.get(opts, :edits, %{}), fn {call, command} ->
          {"HANDOFF_EDIT_#{call}", command}
        end)

    previous = Map.new(env, fn {key, _value} -> {key, System.get_env(key)} end)
    System.delete_env("KOGEN_RAW_LOG_DIR")

    Enum.each(env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)

    try do
      File.cd!(dir, fn -> Kogen.Build.run(@slug) end)
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end

  defp jev_log(dir), do: Path.join(dir, ".kogen/runtime/fake-jev")

  defp fixture!(opts \\ []) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "kogen-controller-handoff-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    for path <- [
          ".codex/hooks/check.sh",
          ".codex/hooks/stop_runner.py",
          ".codex/hooks/environment.py",
          ".codex/hooks/verification_policy.py",
          ".codex/hooks.json",
          "priv/kogen/prompts/execution-policy.md",
          "priv/kogen/prompts/developer.md",
          "priv/kogen/prompts/reviewer.md"
        ] do
      target = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(target))
      File.cp!(Path.join(@root, path), target)
    end

    File.chmod!(Path.join(dir, ".codex/hooks/check.sh"), 0o755)
    File.write!(Path.join(dir, "provider.py"), provider())
    File.chmod!(Path.join(dir, "provider.py"), 0o755)

    File.write!(
      Path.join(dir, "Makefile"),
      ".PHONY: check\n\ncheck:\n\t@test ! -f .kogen/runtime/fail-check\n"
    )

    File.mkdir_p!(Path.join(dir, "priv/kogen"))

    File.write!(Path.join(dir, "priv/kogen/verification_targets.yaml"), """
    targets:
      - name: check
        cost_class: offline-complete
        rank: 0
        dependencies: []
        provider_backed: false
        owner: fixture
    """)

    File.write!(
      Path.join(dir, ".gitignore"),
      ".kogen/build.lock\n.kogen/runtime/\n.kogen/intents/approved/\n"
    )

    File.mkdir_p!(Path.join(dir, ".kogen"))
    File.write!(Path.join(dir, ".kogen/config.yaml"), config())

    for {path, content} <- [
          {"dummy.txt", "baseline\n"},
          {"keep.txt", "preserved\n"},
          {"retired.txt", "retired\n"},
          {@selector, "# focused selector\n"}
        ] do
      File.mkdir_p!(Path.dirname(Path.join(dir, path)))
      File.write!(Path.join(dir, path), content)
    end

    intent = Path.join(dir, ".kogen/intents/approved/#{@slug}")
    File.mkdir_p!(intent)

    File.write!(Path.join(intent, "intent.yaml"), """
    id: 01960000-0000-7000-8000-0000000c0de1
    slug: #{@slug}
    title: Controller handoff fixture
    may_change_guarded_paths: [dummy.txt, keep.txt, retired.txt, #{@late_selector}]
    """)

    scenarios =
      if Keyword.get(opts, :late_selector),
        do: scenarios_data() ++ [late_scenario()],
        else: scenarios_data()

    File.write!(Path.join(intent, "scenarios.yaml"), Jason.encode!(scenarios))
    File.write!(Path.join(intent, "risks.yaml"), Jason.encode!(risks_data()))

    git!(dir, ["init", "-q", "-b", "main"])
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-q", "-m", "baseline"])
    dir
  end

  defp scenarios_data do
    [
      scenario("s-change", [@selector], ["dummy.txt"]),
      scenario("s-preserve", [@selector], ["keep.txt", "retired.txt"])
    ]
  end

  defp late_scenario, do: scenario("s-late", [@late_selector], [@late_selector])

  defp scenario(id, offline, affected) do
    %{
      "id" => id,
      "given" => "a fixture Candidate",
      "when" => "Build settles the Developer turn",
      "then" => "controller code builds the handoff report",
      "wrong_result" => "the Developer's message decides the report",
      "verified_by" => ["check"],
      "evidence" => "scripted provider",
      "proof" => %{
        "offline" => offline,
        "paid_target" => "none",
        "paid_reason" => "offline-sufficient: scripted provider drives the real Build consumer",
        "affected_paths" => affected
      }
    }
  end

  defp risks_data do
    [
      %{
        "id" => "r-shared",
        "scenario_ids" => ["s-change", "s-preserve"],
        "description" => "fixture"
      },
      %{"id" => "r-preserve", "scenario_ids" => ["s-preserve"], "description" => "fixture"}
    ]
  end

  defp config do
    """
    default_route: codex
    routes:
      codex:
        harness: codex
        shaping:   {model: fake, effort: low}
        developer: {model: fake, effort: low}
        reviewer:  {model: fake, effort: low}
        helpers:
          scout:  {model: fake, effort: low}
          worker: {model: fake, effort: medium}
          expert: {model: fake, effort: medium}
    outer_resumptions: 2
    verification_retries: 2
    """
  end

  # A Codex-protocol provider: Developer turns apply HANDOFF_EDIT_<call>,
  # settle the real Stop hook and end with notes-<call> (or default prose);
  # Reviewers answer HANDOFF_REVIEWS in order through scenario_response.py.
  defp provider do
    ~S'''
    #!/usr/bin/env python3
    import json, os, pathlib, subprocess, sys
    runtime = pathlib.Path(".kogen/runtime"); runtime.mkdir(parents=True, exist_ok=True)
    args = sys.argv[1:]; prompt = sys.stdin.read()
    def count(name):
        path = runtime / name
        value = int(path.read_text()) + 1 if path.exists() else 1
        path.write_text(str(value)); return value
    if os.environ.get("KOGEN_ROLE") == "reviewer":
        n = count("reviews")
        (runtime / f"reviewer-prompt-{n}").write_text(prompt)
        verdicts = os.environ.get("HANDOFF_REVIEWS", "accept").split(",")
        verdict = verdicts[min(n, len(verdicts)) - 1]
        out = args[args.index("--output-last-message") + 1]
        response = subprocess.run([sys.executable, os.environ["HANDOFF_RESPONSE_HELPER"], "reviewer", verdict],
                                  input=prompt, capture_output=True, text=True, check=True).stdout
        pathlib.Path(out).write_text(response)
        print(json.dumps({"type": "thread.started", "thread_id": f"review-{n}"}))
        print(json.dumps({"type": "turn.completed", "thread_id": f"review-{n}"}))
        raise SystemExit(0)
    if "--output-last-message" in args or "--output-schema" in args:
        raise SystemExit("Developer turn carried a handoff output schema")
    call = count("developer-calls")
    (runtime / f"developer-prompt-{call}").write_text(prompt)
    edit = os.environ.get(f"HANDOFF_EDIT_{call}")
    if edit: subprocess.run(["sh", "-c", edit], check=True)
    session = "developer-session"
    for _ in range(8):
        hook = subprocess.run(["sh", ".codex/hooks/check.sh"], input=json.dumps({"session_id": session, "thread_id": session}).encode(),
                              capture_output=True, check=True)
        answer = json.loads(hook.stdout)
        if "continue" in answer: break
    notes_file = pathlib.Path(os.environ["HANDOFF_NOTES_DIR"]) / f"notes-{call}"
    notes = notes_file.read_text() if notes_file.exists() else "All scenarios are done; nothing is unfinished."
    print(json.dumps({"type": "thread.started", "thread_id": session}))
    print(json.dumps({"type": "item.completed", "item": {"type": "agent_message", "text": notes}}))
    print(json.dumps({"type": "turn.completed", "thread_id": session}))
    '''
  end

  defp task_context!(prompt) do
    lines = String.split(prompt, "\n")
    index = Enum.find_index(lines, &(&1 == "KOGEN_TASK_CONTEXT"))
    lines |> Enum.at(index + 1) |> Jason.decode!()
  end

  defp record!(dir), do: records(dir) |> List.last() |> File.read!() |> Jason.decode!()

  defp records(dir),
    do: Path.wildcard(Path.join(dir, ".kogen/runtime/scenario-tracking/*/record.json"))

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp git!(dir, args) do
    {_output, 0} =
      System.cmd("git", args,
        cd: dir,
        env: [
          {"GIT_AUTHOR_NAME", "Fixture"},
          {"GIT_AUTHOR_EMAIL", "fixture@example.invalid"},
          {"GIT_COMMITTER_NAME", "Fixture"},
          {"GIT_COMMITTER_EMAIL", "fixture@example.invalid"}
        ]
      )
  end
end
